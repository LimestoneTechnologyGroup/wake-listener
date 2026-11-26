# Claude relay: tells Tyrone what's going on in your Claude Code threads.
#
# Run it on the PC where the Claude desktop app runs your Claude Code threads
# (not necessarily the one with the wake listener). Every two minutes it reads
# the desktop app's session files on this PC (each thread's name, folder,
# whether it's working or done, its last report, anything it needs from you)
# and sends that list to Project Check-in with its own key. Tyrone reads it, so
# "what's going on in my threads?" gets an answer. Read only: it sends nothing
# to the threads and changes nothing on this PC.
#
#   ClaudeRelay.ps1 -Connect     one click on Project Check-in gives it a key
#   ClaudeRelay.ps1 -DryRun      shows what it would send, sends nothing
#   ClaudeRelay.ps1 -Once        sends the list once
#   ClaudeRelay.ps1 -Install     starts it hidden at every sign-in (a scheduled task), and now
#   ClaudeRelay.ps1 -Uninstall   stops it and removes the scheduled task
#   ClaudeRelay.ps1              runs in this window, sending every two minutes
#
# The key is kept encrypted for your Windows account (DPAPI) in
# %LOCALAPPDATA%\ClaudeRelay. Revoke it on Project Check-in's Datalink page.
param([switch]$Connect, [switch]$DryRun, [switch]$Once, [switch]$Install, [switch]$Uninstall, [string]$Base = "https://project-checkin.dev.limestonetg.com")

$ErrorActionPreference = "Stop"
$Version = "1.0.0"
$Folder = Join-Path $env:LOCALAPPDATA "ClaudeRelay"
$KeyFile = Join-Path $Folder "key.txt"
$LogFile = Join-Path $Folder "relay.log"
$TaskName = "Claude relay"
$ThreadsUrl = $Base.TrimEnd("/") + "/api/teams/messages/intake/claude-threads"
$null = New-Item -ItemType Directory -Force $Folder

function Log([string]$text) {
  $line = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "  " + $text
  Write-Host $line
  try {
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    $all = @(Get-Content $LogFile -Encoding UTF8)
    if ($all.Count -gt 400) { Set-Content -Path $LogFile -Value $all[-200..-1] -Encoding UTF8 }
  } catch { }
}

function Get-Key {
  if (-not (Test-Path $KeyFile)) { return $null }
  try { $s = ConvertTo-SecureString ((Get-Content $KeyFile -Raw).Trim()); return [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)) } catch { return $null }
}

# ---- Your threads, as the Claude desktop app records them ----
function Get-Threads {
  $roots = @(Get-ChildItem -Path "$env:LOCALAPPDATA\Claude-Data\*\claude-code-sessions", "$env:APPDATA\Claude\claude-code-sessions" -Directory -ErrorAction SilentlyContinue)
  $since = (Get-Date).AddDays(-2)
  $files = @($roots | ForEach-Object { Get-ChildItem $_.FullName -Recurse -Filter "local_*.json" -File -ErrorAction SilentlyContinue } | Where-Object { $_.LastWriteTime -gt $since })
  $epoch = New-Object DateTime(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
  $threads = @()
  foreach ($f in $files) {
    try { $s = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { continue }
    if ($s.isArchived -or -not $s.lastActivityAt) { continue }
    $title = if ($s.title) { [string]$s.title } elseif ($s.spawnedFrom.name) { [string]$s.spawnedFrom.name } else { "Untitled thread" }
    $place = if ($s.writtenRepositories -and @($s.writtenRepositories).Count) { [string](@($s.writtenRepositories)[0]) } else { [string]$s.cwd }
    $sum = $s.postTurnSummary
    $active = $epoch.AddMilliseconds([double]$s.lastActivityAt)
    # Working: you (or another thread) sent it something after its last turn ended, and it's been busy in the last half hour.
    $working = $s.latestUserFrameAt -and $s.lastTurnEdgeAt -and ([double]$s.latestUserFrameAt -gt [double]$s.lastTurnEdgeAt) -and (((Get-Date).ToUniversalTime() - $active).TotalMinutes -lt 30)
    $needs = if ($sum -and $sum.needs_action) { [string]$sum.needs_action } else { "" }
    $state = if ($working) { "working" } elseif ($s.interruptedAwaitingPerson -or $needs) { "needs_you" } elseif ($sum -and $sum.status_category -eq "completed") { "done" } else { "idle" }
    $report = if ($s.lastTurnReport) { [string]$s.lastTurnReport } elseif ($s.turnWrapUp -and $s.turnWrapUp.description) { [string]$s.turnWrapUp.description } else { "" }
    $threads += [ordered]@{
      id = [string]$s.sessionId; title = $title; folder = $(if ($place) { Split-Path $place -Leaf } else { "" }); state = $state
      detail = $(if ($sum -and $sum.status_detail) { [string]$sum.status_detail } else { "" }); needs = $needs
      report = $(if ($report.Length -gt 600) { $report.Substring(0, 600) } else { $report })
      lastActivityAt = $active.ToString("o")
    }
  }
  return $threads
}

function Send-Threads([string]$key) {
  $threads = @(Get-Threads)
  $body = ConvertTo-Json -InputObject @{ threads = @($threads) } -Depth 4 -Compress
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $web = New-Object System.Net.WebClient
  $web.Headers["Authorization"] = "Bearer $key"; $web.Headers["User-Agent"] = "ClaudeRelay/$Version"; $web.Headers["Content-Type"] = "application/json"; $web.Encoding = [Text.Encoding]::UTF8
  [void]$web.UploadString($ThreadsUrl, "POST", $body)
  $working = @($threads | Where-Object { $_.state -eq "working" }).Count
  $needs = @($threads | Where-Object { $_.state -eq "needs_you" }).Count
  return "Sent $(@($threads).Count) threads ($working working, $needs waiting on you)."
}

function Why($err) { $e = $err.Exception; while ($e.InnerException) { $e = $e.InnerException }; $m = $e.Message; if ($m -match "\(401\)") { return "the key was refused: run ClaudeRelay.ps1 -Connect again" }; return $m }

# ---- -Connect: one click on Project Check-in hands this PC a key ----
if ($Connect) {
  $rnd = New-Object System.Random
  $state = -join (1..32 | ForEach-Object { "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"[$rnd.Next(62)] })
  $server = $null
  foreach ($try in 1..10) {
    $port = $rnd.Next(49200, 64000)
    $candidate = New-Object System.Net.HttpListener
    $candidate.Prefixes.Add("http://localhost:$port/")
    try { $candidate.Start(); $server = $candidate; break } catch { $candidate.Close() }
  }
  if (-not $server) { Write-Host "Couldn't open a local port to receive the key. Try again." -ForegroundColor Red; exit 1 }
  $page = $Base.TrimEnd("/") + "/settings/datalink/listener?port=$port&state=$state&for=relay"
  Write-Host "Press Connect Claude relay on the page that opened (this waits five minutes)." -ForegroundColor Cyan
  Start-Process $page
  $task = $server.GetContextAsync(); $until = (Get-Date).AddMinutes(5); $ok = $false
  while (-not $ok -and (Get-Date) -lt $until) {
    if (-not $task.Wait(1000)) { continue }
    $ctx = $task.Result
    try {
      if ($ctx.Request.HttpMethod -eq "POST" -and $ctx.Request.Url.AbsolutePath -eq "/connect") {
        $body = (New-Object System.IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
        $form = @{}
        foreach ($pair in $body.Split("&")) { $kv = $pair.Split("=", 2); if ($kv.Count -eq 2) { $form[[Uri]::UnescapeDataString($kv[0].Replace("+", " "))] = [Uri]::UnescapeDataString($kv[1].Replace("+", " ")) } }
        if ($form["state"] -eq $state -and $form["key"] -match "^pci_[A-Za-z0-9_-]{20,100}$") {
          Set-Content -Path $KeyFile -Value (ConvertFrom-SecureString (ConvertTo-SecureString $form["key"] -AsPlainText -Force)) -Encoding ASCII
          $ok = $true
        }
      }
      $html = if ($ok) { "<!doctype html><meta charset=utf-8><title>Connected</title><body style='font-family:Segoe UI,sans-serif;padding:40px'><h1>Connected</h1><p>The Claude relay on this PC can now tell Tyrone about your Claude Code threads. You can close this window.</p>" } else { "<!doctype html><meta charset=utf-8><title>Not connected</title><body style='font-family:Segoe UI,sans-serif;padding:40px'><h1>Not connected</h1><p>That didn't come from this connect. Run ClaudeRelay.ps1 -Connect again.</p>" }
      $bytes = [Text.Encoding]::UTF8.GetBytes($html)
      $ctx.Response.ContentType = "text/html; charset=utf-8"; $ctx.Response.StatusCode = $(if ($ok) { 200 } else { 400 })
      $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length); $ctx.Response.Close()
    } catch { }
    if (-not $ok) { $task = $server.GetContextAsync() }
  }
  Start-Sleep -Seconds 2; $server.Stop(); $server.Close()
  if (-not $ok) { Write-Host "Not connected: the five minutes ran out. Run ClaudeRelay.ps1 -Connect again." -ForegroundColor Yellow; exit 1 }
  Log "Connected to Project Check-in."
  try { Log (Send-Threads (Get-Key)) } catch { Log ("Not sent: " + (Why $_)) }
  Write-Host "Next: ClaudeRelay.ps1 -Install keeps it running whenever you're signed in." -ForegroundColor Green
  exit 0
}

# ---- -Install / -Uninstall: a scheduled task that starts it hidden at sign-in ----
if ($Install) {
  if (-not (Get-Key)) { Write-Host "Connect it first: ClaudeRelay.ps1 -Connect" -ForegroundColor Yellow; exit 1 }
  # It runs from its own copy, so editing or moving this file later changes nothing.
  $self = Join-Path $Folder "ClaudeRelay.ps1"
  if ($MyInvocation.MyCommand.Path -ne $self) { Copy-Item -LiteralPath $MyInvocation.MyCommand.Path -Destination $self -Force }
  $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$self`" -Base `"$Base`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Tells Tyrone (Project Check-in) what's going on in your Claude Code threads. $self" -Force | Out-Null
  Start-ScheduledTask -TaskName $TaskName
  Log "Installed: starts at sign-in, running now."
  exit 0
}
if ($Uninstall) {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
  Log "Uninstalled: the scheduled task is gone. The key stays until you revoke it on the Datalink page."
  exit 0
}

if ($DryRun) { ConvertTo-Json -InputObject @{ threads = @(Get-Threads) } -Depth 4; exit 0 }

$key = Get-Key
if (-not $key) { Write-Host "Not connected yet: run ClaudeRelay.ps1 -Connect" -ForegroundColor Yellow; exit 1 }
if ($Once) { try { Log (Send-Threads $key); exit 0 } catch { Log ("Not sent: " + (Why $_)); exit 1 } }

# One relay at a time.
$mutex = New-Object System.Threading.Mutex($false, "Local\ClaudeRelay")
if (-not $mutex.WaitOne(0)) { Write-Host "The Claude relay is already running." -ForegroundColor Yellow; exit 0 }
Log "Claude relay $Version running: sending your threads every two minutes."
$lastNote = ""
while ($true) {
  $key = Get-Key
  $note = if (-not $key) { "Not connected: run ClaudeRelay.ps1 -Connect" } else { try { Send-Threads $key } catch { "Not sent: " + (Why $_) } }
  # The log gets a line when something changes, not every two minutes.
  if ($note -ne $lastNote) { Log $note; $lastNote = $note }
  Start-Sleep -Seconds 120
}
