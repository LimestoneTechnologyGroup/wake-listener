# Claude relay: Tyrone and your Claude Code threads.
#
# Run it on the PC where the Claude desktop app runs your Claude Code threads
# (not necessarily the one with the wake listener). It does two things:
#
# 1. Every two minutes it reads the desktop app's session files on this PC
#    (each thread's name, folder, whether it's working or done, its last report,
#    anything it needs from you) and sends that list to Project Check-in with its
#    own key, so "what's going on in my threads?" gets an answer.
# 2. Every 20 seconds it checks for Claude Code jobs Tyrone was asked to send
#    ("tell the project-checkin thread to fix the Ask button"). Each runs in the
#    background with this PC's Claude Code, in one of your project folders only
#    (a folder where a Claude Code thread has run in the last 30 days), with
#    file edits allowed and any command your project hasn't allowed refused. A
#    job for a thread picks up from that thread's conversation in a copy, so the
#    thread itself is untouched. The result goes back to Tyrone and your chat.
#    Claude Code here needs signing in once: see -Doctor.
#
#   ClaudeRelay.ps1 -Connect     one click on Project Check-in gives it a key
#   ClaudeRelay.ps1 -Doctor      checks Claude Code is here and signed in, and lists the folders jobs can use
#   ClaudeRelay.ps1 -DryRun      shows what it would send, sends nothing
#   ClaudeRelay.ps1 -Once        sends the list once
#   ClaudeRelay.ps1 -Install     starts it hidden at every sign-in (a scheduled task), and now
#   ClaudeRelay.ps1 -Uninstall   stops it and removes the scheduled task
#   ClaudeRelay.ps1              runs in this window, sending every two minutes
#
# The key is kept encrypted for your Windows account (DPAPI) in
# %LOCALAPPDATA%\ClaudeRelay. Revoke it on Project Check-in's Datalink page.
param([switch]$Connect, [switch]$Doctor, [switch]$DryRun, [switch]$Once, [switch]$Install, [switch]$Uninstall, [string]$Base = "https://project-checkin.dev.limestonetg.com")

$ErrorActionPreference = "Stop"
$Version = "2.0.0"
# CLAUDE_RELAY_HOME and CLAUDE_RELAY_CLAUDE are for testing: another folder for its files, another Claude Code.
$Folder = if ($env:CLAUDE_RELAY_HOME) { $env:CLAUDE_RELAY_HOME } else { Join-Path $env:LOCALAPPDATA "ClaudeRelay" }
$KeyFile = Join-Path $Folder "key.txt"
$LogFile = Join-Path $Folder "relay.log"
$TaskName = "Claude relay"
$ThreadsUrl = $Base.TrimEnd("/") + "/api/teams/messages/intake/claude-threads"
$TasksUrl = $Base.TrimEnd("/") + "/api/teams/messages/intake/tasks"
$JobsDir = Join-Path $Folder "jobs"
$MaxRunning = 2
$JobMinutes = 45
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
function Get-SessionFiles([int]$days) {
  $roots = @(Get-ChildItem -Path "$env:LOCALAPPDATA\Claude-Data\*\claude-code-sessions", "$env:APPDATA\Claude\claude-code-sessions" -Directory -ErrorAction SilentlyContinue)
  $since = (Get-Date).AddDays(-$days)
  return @($roots | ForEach-Object { Get-ChildItem $_.FullName -Recurse -Filter "local_*.json" -File -ErrorAction SilentlyContinue } | Where-Object { $_.LastWriteTime -gt $since })
}

# Where jobs may run: the project folders Claude Code threads used in the last 30 days, by folder name.
# A thread's own worktree is never one; the project it came from is.
function Get-JobFolders {
  $map = @{}
  foreach ($f in (Get-SessionFiles 30)) {
    try { $s = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { continue }
    foreach ($p in @($s.originCwd, $s.cwd) + @($s.writtenRepositories)) {
      if (-not $p) { continue }
      $p = [string]$p
      if ($p -match '[\\/]\.claude[\\/]worktrees[\\/]' -or -not (Test-Path -LiteralPath $p -PathType Container)) { continue }
      # Never the app's own scratch space or temp folders.
      if (@($env:LOCALAPPDATA, $env:APPDATA, $env:TEMP) | Where-Object { $_ -and $p.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) { continue }
      $name = Split-Path $p -Leaf
      if ($name -and -not $map.ContainsKey($name.ToLower())) { $map[$name.ToLower()] = @{ name = $name; path = (Resolve-Path -LiteralPath $p).Path } }
    }
  }
  # Never a folder that holds other project folders (C:\...\Projects): a job gets one project.
  foreach ($k in @($map.Keys)) { $inside = $map[$k].path.TrimEnd('\') + '\'; if (@($map.Values | Where-Object { $_.path.StartsWith($inside, [StringComparison]::OrdinalIgnoreCase) }).Count) { $map.Remove($k) } }
  return $map
}

# One thread's session file, by its id (local_...).
function Get-Session([string]$id) {
  foreach ($f in (Get-SessionFiles 30)) {
    if ($f.BaseName -ne $id) { continue }
    try { return [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch { return $null }
  }
  return $null
}

function Get-Threads {
  $files = Get-SessionFiles 2
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
  $folders = @((Get-JobFolders).Values | ForEach-Object { $_.name } | Sort-Object)
  $body = ConvertTo-Json -InputObject @{ threads = @($threads); folders = $folders } -Depth 4 -Compress
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $web = New-Object System.Net.WebClient
  $web.Headers["Authorization"] = "Bearer $key"; $web.Headers["User-Agent"] = "ClaudeRelay/$Version"; $web.Headers["Content-Type"] = "application/json"; $web.Encoding = [Text.Encoding]::UTF8
  [void]$web.UploadString($ThreadsUrl, "POST", $body)
  $working = @($threads | Where-Object { $_.state -eq "working" }).Count
  $needs = @($threads | Where-Object { $_.state -eq "needs_you" }).Count
  return "Sent $(@($threads).Count) threads ($working working, $needs waiting on you)."
}

# ---- Claude Code jobs from Tyrone ----
function Web([string]$key) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $web = New-Object System.Net.WebClient
  $web.Headers["Authorization"] = "Bearer $key"; $web.Headers["User-Agent"] = "ClaudeRelay/$Version"; $web.Encoding = [Text.Encoding]::UTF8
  return $web
}

function Report([string]$key, [string]$id, [string]$status, [string]$text) {
  $body = if ($status -eq "working") { @{ status = $status; progress = $text } } else { @{ status = $status; result = $text } }
  $web = Web $key; $web.Headers["Content-Type"] = "application/json"
  try { [void]$web.UploadString("$TasksUrl/$id", "POST", (ConvertTo-Json -InputObject $body -Compress)); return $true }
  catch { if ($_.Exception.Message -match "\(409\)") { return $false }; throw }
}

# This PC's Claude Code: the copy the desktop app keeps (newest), or claude on the PATH.
function Find-Claude {
  if ($env:CLAUDE_RELAY_CLAUDE) { return $env:CLAUDE_RELAY_CLAUDE }
  $bundled = Get-ChildItem "$env:LOCALAPPDATA\Claude-Data\*\claude-code\*\*\claude.exe", "$env:APPDATA\Claude\claude-code\*\*\claude.exe" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($bundled) { return $bundled.FullName }
  $onPath = Get-Command claude -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($onPath) { return $onPath.Source }
  return $null
}

$script:ReadyAt = [DateTime]::MinValue; $script:Ready = $null
# Null when Claude Code is here and signed in; otherwise what to do about it. Checked every ten minutes.
function Claude-Problem {
  if ($script:Ready -ne $null -and ((Get-Date) - $script:ReadyAt).TotalMinutes -lt 10) { return $script:Ready }
  $exe = Find-Claude
  $problem = if (-not $exe) { "Claude Code isn't on the PC: open the Claude desktop app's Code tab once, so it's downloaded." } else {
    $status = try { (& $exe auth status 2>$null | Out-String) | ConvertFrom-Json } catch { $null }
    if ($status -and $status.loggedIn) { "" } else { "Claude Code on your PC isn't signed in for jobs yet. On that PC, run ClaudeRelay.ps1 -Doctor and follow its one step to sign in, then ask again." }
  }
  $script:Ready = $problem; $script:ReadyAt = Get-Date
  return $problem
}

function Job-Prompt($t, [string]$project) {
  $from = if ($t.from) { [string]$t.from } else { "you" }
  return @"
This job was sent by Tyrone, $from's assistant, from a phone call or chat, and is running in the background with no one watching. Do it in the $(Split-Path $project -Leaf) project ($project):

$($t.task)

Work only in that project folder. If something you need isn't allowed or isn't clear, don't guess: stop and say what's needed. Finish with a short plain summary (a few sentences) of what you did, what changed, and anything left for $from to do; it's read to them by Tyrone.
"@
}

function Start-Job($key, $t) {
  $id = [string]$t.id
  $dir = Join-Path $JobsDir $id
  if (Test-Path $dir) { return }
  $null = New-Item -ItemType Directory -Force $dir
  $problem = Claude-Problem
  if ($problem) { Report $key $id "failed" $problem | Out-Null; Set-Content (Join-Path $dir "done.txt") "failed: not ready"; Log "Job $id not run: $problem"; return }
  $exe = Find-Claude
  $cliArgs = @("-p", "--output-format", "json", "--permission-mode", "acceptEdits")
  $where = $null; $fresh = ""
  $allowed = @((Get-JobFolders).Values | ForEach-Object { $_.path })
  if ($t.claude.thread_id) {
    $s = Get-Session ([string]$t.claude.thread_id)
    $cli = if ($s) { if ($s.cliSessionId) { [string]$s.cliSessionId } else { [string]$s.lastAssistantCliSessionId } } else { "" }
    # Only a thread that ran in one of the project folders (or a worktree of one) is picked up from; its conversation is kept by folder, so it runs there.
    $cwd = if ($s -and $s.cwd) { ([string]$s.cwd).TrimEnd("\") } else { "" }
    $inProject = $cwd -and @($allowed | Where-Object { $cwd -ieq $_ -or $cwd.StartsWith($_ + "\.claude\worktrees\", [StringComparison]::OrdinalIgnoreCase) }).Count
    # Or a folder in their profile that holds their projects (threads often start in C:\...\Projects and work in one): the job is told to stay in its project.
    $underProfile = $cwd -and $cwd.StartsWith($env:USERPROFILE + "\", [StringComparison]::OrdinalIgnoreCase) -and -not (@($env:LOCALAPPDATA, $env:APPDATA, $env:TEMP) | Where-Object { $_ -and $cwd.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })
    if (-not $inProject -and $underProfile) { $inProject = @($allowed | Where-Object { $_.StartsWith($cwd + "\", [StringComparison]::OrdinalIgnoreCase) }).Count }
    if (-not ($s -and $cli -and $inProject)) { $fresh = " (starting fresh: that thread can't be picked up from here)" }
    if ($s -and $cli -and $inProject -and (Test-Path -LiteralPath $cwd -PathType Container)) {
      $where = $cwd
      # A copy of the thread's conversation (--fork-session): the thread itself is never changed.
      $cliArgs += @("--resume", $cli, "--fork-session")
    }
  }
  if (-not $where) {
    $match = (Get-JobFolders)[([string]$t.claude.folder).ToLower()]
    if ($match) { $where = $match.path }
  }
  if (-not $where) { Report $key $id "failed" "The folder $($t.claude.folder) isn't one of your project folders on this PC (where a Claude Code thread has run in the last 30 days), so nothing was run." | Out-Null; Set-Content (Join-Path $dir "done.txt") "failed: no folder"; return }
  $project = $where
  $named = (Get-JobFolders)[([string]$t.claude.folder).ToLower()]
  if ($named -and ($where -ieq $named.path -or $named.path.StartsWith($where + "\", [StringComparison]::OrdinalIgnoreCase))) { $project = $named.path }
  [IO.File]::WriteAllText((Join-Path $dir "prompt.txt"), (Job-Prompt $t $project), (New-Object Text.UTF8Encoding($false)))
  $p = Start-Process -FilePath $exe -ArgumentList $cliArgs -WorkingDirectory $where -RedirectStandardInput (Join-Path $dir "prompt.txt") -RedirectStandardOutput (Join-Path $dir "out.json") -RedirectStandardError (Join-Path $dir "err.txt") -NoNewWindow -PassThru
  ConvertTo-Json @{ pid = $p.Id; started = (Get-Date).ToString("o"); where = $where; task = [string]$t.task } | Set-Content (Join-Path $dir "job.json") -Encoding UTF8
  Log "Job $id started in $where$(if ($t.claude.thread_id) { ' (from thread ' + $t.claude.thread_title + ')' })."
  Report $key $id "working" "Claude Code started on the PC, in $(Split-Path $project -Leaf)$fresh." | Out-Null
}

# What a finished job said: its summary, plus anything it was refused.
function Job-Result([string]$dir) {
  $raw = try { Get-Content (Join-Path $dir "out.json") -Raw -Encoding UTF8 } catch { "" }
  $out = try { $raw | ConvertFrom-Json } catch { $null }
  if (-not $out) {
    $err = try { (Get-Content (Join-Path $dir "err.txt") -Raw -Encoding UTF8).Trim() } catch { "" }
    return @{ ok = $false; text = "Claude Code stopped without a result. $(if ($err) { $err.Substring(0, [Math]::Min(500, $err.Length)) })" }
  }
  $text = [string]$out.result
  $denied = @($out.permission_denials).Count
  if ($denied) { $text += "`n`n($denied step$(if ($denied -ne 1) { 's' }) needed permission that a background job doesn't have, such as running a command your project hasn't allowed, so $(if ($denied -ne 1) { 'they were' } else { 'it was' }) skipped. Open the thread to do $(if ($denied -ne 1) { 'those' } else { 'that' }) yourself.)" }
  return @{ ok = -not $out.is_error; text = $text }
}

function Check-Jobs($key, $openIds) {
  foreach ($d in @(Get-ChildItem $JobsDir -Directory -ErrorAction SilentlyContinue)) {
    if (Test-Path (Join-Path $d.FullName "done.txt")) { continue }
    $jf = Join-Path $d.FullName "job.json"
    if (-not (Test-Path $jf)) { continue }
    $job = Get-Content $jf -Raw | ConvertFrom-Json
    $proc = Get-Process -Id ([int]$job.pid) -ErrorAction SilentlyContinue
    $running = $proc -and -not $proc.HasExited -and $proc.ProcessName -match "claude"
    $age = ((Get-Date) - [DateTime]::Parse([string]$job.started)).TotalMinutes
    if ($running -and $openIds -ne $null -and -not ($openIds -contains $d.Name)) {
      # Cancelled on Project Check-in.
      Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue; Set-Content (Join-Path $d.FullName "done.txt") "cancelled"; Log "Job $($d.Name) cancelled."; continue
    }
    if ($running -and $age -lt $JobMinutes) { continue }
    if ($running) {
      Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
      $r = @{ ok = $false; text = "Claude Code was still going after $JobMinutes minutes, so the job was stopped. Open the project on the PC to see how far it got." }
    } else { $r = Job-Result $d.FullName }
    try {
      $null = Report $key $d.Name $(if ($r.ok) { "done" } else { "failed" }) $(if ($r.text.Trim()) { $r.text.Trim() } else { "Done (Claude Code gave no summary)." })
      Set-Content (Join-Path $d.FullName "done.txt") $(if ($r.ok) { "done" } else { "failed" })
      Log "Job $($d.Name) $(if ($r.ok) { 'done' } else { 'failed' })."
    } catch { Log ("Job $($d.Name) result not sent yet: " + (Why $_)) }
  }
}

function Poll-Jobs([string]$key) {
  $null = New-Item -ItemType Directory -Force $JobsDir
  $tasks = @(((Web $key).DownloadString($TasksUrl) | ConvertFrom-Json).tasks)
  $open = @($tasks | ForEach-Object { [string]$_.id })
  Check-Jobs $key $open
  $running = @(Get-ChildItem $JobsDir -Directory -ErrorAction SilentlyContinue | Where-Object { (Test-Path (Join-Path $_.FullName "job.json")) -and -not (Test-Path (Join-Path $_.FullName "done.txt")) }).Count
  foreach ($t in $tasks) {
    if (-not $t.claude) { continue }
    if (Test-Path (Join-Path $JobsDir ([string]$t.id))) { continue }
    if ($running -ge $MaxRunning) { break }
    Start-Job $key $t
    $running++
  }
  # Old job folders go after a week.
  Get-ChildItem $JobsDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) -and (Test-Path (Join-Path $_.FullName "done.txt")) } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
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

if ($Doctor) {
  $exe = Find-Claude
  if (-not $exe) { Write-Host "Claude Code: not found. Open the Claude desktop app's Code tab once, so it's downloaded." -ForegroundColor Yellow } else {
    Write-Host "Claude Code: $exe"
    $script:Ready = $null
    $problem = Claude-Problem
    if ($problem) {
      Write-Host "Signed in for jobs: no. One step, on this PC (it opens a browser to sign in to your Claude account):" -ForegroundColor Yellow
      Write-Host "  & `"$exe`" auth login" -ForegroundColor Cyan
    } else { Write-Host "Signed in for jobs: yes" -ForegroundColor Green }
  }
  Write-Host ("Connected to Project Check-in: " + $(if (Get-Key) { "yes" } else { "no (run ClaudeRelay.ps1 -Connect)" }))
  Write-Host "Folders jobs can run in (where a Claude Code thread ran in the last 30 days):"
  (Get-JobFolders).Values | Sort-Object { $_.name } | ForEach-Object { Write-Host ("  " + $_.name + "  " + $_.path) }
  exit 0
}

if ($DryRun) { ConvertTo-Json -InputObject @{ threads = @(Get-Threads); folders = @((Get-JobFolders).Values | ForEach-Object { $_.name } | Sort-Object) } -Depth 4; exit 0 }

$key = Get-Key
if (-not $key) { Write-Host "Not connected yet: run ClaudeRelay.ps1 -Connect" -ForegroundColor Yellow; exit 1 }
if ($Once) { try { Log (Send-Threads $key); exit 0 } catch { Log ("Not sent: " + (Why $_)); exit 1 } }

# One relay at a time.
$mutex = New-Object System.Threading.Mutex($false, "Local\ClaudeRelay")
if (-not $mutex.WaitOne(0)) { Write-Host "The Claude relay is already running." -ForegroundColor Yellow; exit 0 }
Log "Claude relay $Version running: sending your threads every two minutes, checking for jobs every 20 seconds."
$lastNote = ""; $lastJobNote = ""; $nextThreads = Get-Date
while ($true) {
  $key = Get-Key
  if ((Get-Date) -ge $nextThreads) {
    $note = if (-not $key) { "Not connected: run ClaudeRelay.ps1 -Connect" } else { try { Send-Threads $key } catch { "Not sent: " + (Why $_) } }
    # The log gets a line when something changes, not every two minutes.
    if ($note -ne $lastNote) { Log $note; $lastNote = $note }
    $nextThreads = (Get-Date).AddMinutes(2)
  }
  if ($key) {
    $jobNote = try { Poll-Jobs $key; "" } catch { "Jobs not checked: " + (Why $_) }
    if ($jobNote -ne $lastJobNote) { if ($jobNote) { Log $jobNote }; $lastJobNote = $jobNote }
  }
  Start-Sleep -Seconds 20
}
