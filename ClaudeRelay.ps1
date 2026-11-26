# Claude relay: Tyrone and your Claude Code threads.
#
# Run it on the PC where the Claude desktop app runs your Claude Code threads
# (not necessarily the one with the wake listener). It does two things:
#
# 1. Every two minutes it reads the desktop app's session files on this PC
#    (each thread's name, folder, whether it's working or done, its last report,
#    anything it needs from you) and sends that list to Project Check-in with its
#    own key, so "what's going on in my threads?" gets an answer.
# 2. Every Claude Code job Tyrone sends goes to one Tyrone thread: a Claude
#    Code session on this PC, picked up again for each job (one at a time), so
#    it remembers what came before. It works in its own folder, outside your
#    projects, and only dispatches: every change, however small, goes to a
#    subthread (up to 5 run at once), each in its own git worktree of one
#    project, on its own branch (tyrone/...), committed by the relay when it
#    finishes and then closed. Nothing ever lands on the branch you work on.
#    File edits are allowed; any command your project hasn't allowed is
#    refused. Results go back to Tyrone and your chat. Claude Code here needs
#    signing in once: see -Doctor.
#    Going live (3.3.0): when a subthread's checks pass in a project with
#    go-live steps below ($GoLive), the relay itself (not Claude) merges its
#    branch into main, runs the checks again on the merged code, pushes main
#    and dev, and deploys, posting each step to your Tyrone chat and Talk.
# 3. While anything runs, every few seconds it sends what the Tyrone thread and
#    each subthread are doing, step by step (reading a file, editing one,
#    running the tests), so Talk shows it live.
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
param([switch]$Connect, [switch]$Doctor, [switch]$DryRun, [switch]$Once, [switch]$Install, [switch]$Uninstall, [string]$Ship = "", [string]$Base = "https://project-checkin.dev.limestonetg.com")

$ErrorActionPreference = "Stop"
$Version = "3.3.0"
# CLAUDE_RELAY_HOME and CLAUDE_RELAY_CLAUDE are for testing: another folder for its files, another Claude Code.
$Folder = if ($env:CLAUDE_RELAY_HOME) { $env:CLAUDE_RELAY_HOME } else { Join-Path $env:LOCALAPPDATA "ClaudeRelay" }
$KeyFile = Join-Path $Folder "key.txt"
$LogFile = Join-Path $Folder "relay.log"
$TaskName = "Claude relay"
$ThreadsUrl = $Base.TrimEnd("/") + "/api/teams/messages/intake/claude-threads"
$TasksUrl = $Base.TrimEnd("/") + "/api/teams/messages/intake/tasks"
$LiveUrl = $Base.TrimEnd("/") + "/api/teams/messages/intake/claude-live"
$JobsDir = Join-Path $Folder "jobs"
$SubDir = Join-Path $Folder "subthreads"
$SpawnDir = Join-Path $Folder "spawn"
$WtDir = Join-Path $Folder "wt"
$TyroneFile = Join-Path $Folder "tyrone.json"
# The Tyrone thread works here, outside every project: it can't change a project itself, so every change goes on a branch.
$TyroneHome = Join-Path $Folder "tyrone"
$MaxSubthreads = 5
# What a subthread may run without asking (Zack, 2026-11-26): its project's checks, and committing on its own
# branch. Never push, deploy, switch branches or delete: anything else is refused.
$CheckCommands = @("npm run test", "npm run typecheck", "npm run lint", "npm run check", "npm test", "npx tsc", "npx vitest", "npx eslint", "npx playwright test", "node --check", "python -m pytest", "pytest", "git status", "git diff", "git log", "git show", "git add", "git commit")
$SubthreadTools = @($CheckCommands | ForEach-Object { "Bash($($_):*)"; "PowerShell($($_):*)" })
$JobMinutes = 45
# Going live (Zack, 2026-11-26: "push all the way to dev, if I can see it in the chat"). A subthread that committed
# with its checks passing, in one of these projects, is merged into main, checked again, pushed to main and the
# deploy branch, and deployed, by the relay itself: subthreads still can't push. Other projects stay on their branch.
# host/deploy/status are left out for a project that deploys on push. CLAUDE_RELAY_GOLIVE (a JSON file) is for testing.
$GoLive = @{
  "project-checkin" = @{ branch = "dev"; checks = @("npm run typecheck", "npm test"); host = "zack@162.35.15.207"; deploy = "sudo -n ltg-dev-deploy run project-checkin"; status = "sudo -n ltg-dev-deploy status project-checkin"; app = "project-checkin" }
}
if ($env:CLAUDE_RELAY_GOLIVE) { $GoLive = @{}; foreach ($p in (Get-Content $env:CLAUDE_RELAY_GOLIVE -Raw | ConvertFrom-Json).PSObject.Properties) { $GoLive[$p.Name.ToLower()] = @{ branch = $p.Value.branch; checks = @($p.Value.checks); host = $p.Value.host; deploy = $p.Value.deploy; status = $p.Value.status; app = $p.Value.app } } }
$GoLiveMinutes = 20
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

# ---- Claude Code jobs from Tyrone: one Tyrone thread, and its subthreads ----
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

function Read-Json([string]$path) { if (-not (Test-Path -LiteralPath $path)) { return $null }; try { return ([IO.File]::ReadAllText($path) | ConvertFrom-Json) } catch { return $null } }
function Write-Json([string]$path, $value) { [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $value -Depth 6), (New-Object Text.UTF8Encoding($false))) }
function Clip([string]$s, [int]$max) { $s = ($s -replace '\s+', ' ').Trim(); if ($s.Length -gt $max) { return $s.Substring(0, $max).TrimEnd() + "…" }; return $s }

# The Tyrone thread's state: its Claude Code session, and notes for its next job (subthreads that finished since).
function Get-Tyrone { $t = Read-Json $TyroneFile; if (-not $t) { $t = [pscustomobject]@{ sessionId = ""; notes = @() } }; if (-not $t.notes) { $t | Add-Member -Force notes @() }; return $t }
function Add-Note([string]$text) { $t = Get-Tyrone; $t.notes = @(@($t.notes) + $text | Select-Object -Last 20); Write-Json $TyroneFile $t }

# ---- What a run is doing, step by step, from Claude Code's stream ----
$script:Streams = @{}
function Step-Texts($ev) {
  $out = @()
  if ($ev.type -ne "assistant" -or -not $ev.message.content) { return $out }
  foreach ($c in @($ev.message.content)) {
    if ($c.type -eq "text" -and ([string]$c.text).Trim()) { $out += Clip ([string]$c.text) 160; continue }
    if ($c.type -ne "tool_use") { continue }
    $i = $c.input
    $leaf = if ($i.file_path) { Split-Path ([string]$i.file_path) -Leaf } elseif ($i.notebook_path) { Split-Path ([string]$i.notebook_path) -Leaf } else { "" }
    switch -Regex ([string]$c.name) {
      '^Read$' { $out += "Reading $leaf" }
      '^(Edit|MultiEdit|NotebookEdit)$' { $out += "Editing $leaf" }
      '^Write$' { $out += "Writing $leaf" }
      '^Bash$|^PowerShell$' { $out += "Running: " + (Clip ([string]$i.command) 80) }
      '^(Grep|Glob)$' { $out += "Searching the code" }
      '^(Task|Agent)$' { $out += "Starting a helper: " + (Clip ([string]$i.description) 80) }
      '^(WebFetch|WebSearch)$' { $out += "Looking it up online" }
      '^(TodoWrite|TaskCreate|TaskUpdate)$' { }
      default { $out += "Using " + [string]$c.name }
    }
  }
  return $out
}

# Reads what's new in a run's output (out.json, one event a line) and keeps its last steps and session.
function Read-Stream([string]$dir) {
  $s = $script:Streams[$dir]
  if (-not $s) { $s = @{ pos = 0; rest = ""; steps = New-Object System.Collections.ArrayList; session = "" }; $script:Streams[$dir] = $s }
  $file = Join-Path $dir "out.json"
  if (-not (Test-Path -LiteralPath $file)) { return $s }
  try {
    $fs = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { [void]$fs.Seek($s.pos, [IO.SeekOrigin]::Begin); $buf = New-Object byte[] ($fs.Length - $s.pos); $n = $fs.Read($buf, 0, $buf.Length); $s.pos += $n }
    finally { $fs.Close() }
    $text = $s.rest + [Text.Encoding]::UTF8.GetString($buf, 0, $n)
    $lines = @($text -split "`n")
    $s.rest = $lines[-1]
    $whole = if ($lines.Count -gt 1) { $lines[0..($lines.Count - 2)] } else { @() }
    foreach ($line in $whole) {
      if (-not $line.Trim()) { continue }
      $ev = try { $line | ConvertFrom-Json } catch { $null }
      if (-not $ev) { continue }
      if ($ev.session_id -and -not $s.session) { $s.session = [string]$ev.session_id }
      foreach ($step in (Step-Texts $ev)) { [void]$s.steps.Add(@{ at = (Get-Date).ToUniversalTime().ToString("o"); text = $step }); while ($s.steps.Count -gt 15) { $s.steps.RemoveAt(0) } }
    }
  } catch { }
  return $s
}

# What a finished run said: its summary, plus anything it was refused.
function Run-Result([string]$dir) {
  $lines = try { [IO.File]::ReadAllLines((Join-Path $dir "out.json")) } catch { @() }
  $out = $null
  foreach ($l in $lines) { if ($l -match '"type"\s*:\s*"result"') { $out = try { $l | ConvertFrom-Json } catch { $null } } }
  if (-not $out) {
    $err = try { (Get-Content (Join-Path $dir "err.txt") -Raw -Encoding UTF8).Trim() } catch { "" }
    return @{ ok = $false; text = "Claude Code stopped without a result. $(if ($err) { $err.Substring(0, [Math]::Min(500, $err.Length)) })"; session = "" }
  }
  $text = [string]$out.result
  $denied = @($out.permission_denials).Count
  if ($denied) { $text += "`n`n($denied step$(if ($denied -ne 1) { 's' }) needed permission that a background job doesn't have, such as running a command your project hasn't allowed, so $(if ($denied -ne 1) { 'they were' } else { 'it was' }) skipped.)" }
  return @{ ok = -not $out.is_error; text = $text; session = [string]$out.session_id }
}

function Start-Claude([string]$dir, [string]$where, [string[]]$extra, [string]$prompt) {
  [IO.File]::WriteAllText((Join-Path $dir "prompt.txt"), $prompt, (New-Object Text.UTF8Encoding($false)))
  $cliArgs = @("-p", "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits") + $extra
  # PowerShell 5.1 joins ArgumentList with spaces and no quoting: anything with a space ("Bash(npm test:*)") is quoted here.
  $line = ($cliArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join " "
  return Start-Process -FilePath (Find-Claude) -ArgumentList $line -WorkingDirectory $where -RedirectStandardInput (Join-Path $dir "prompt.txt") -RedirectStandardOutput (Join-Path $dir "out.json") -RedirectStandardError (Join-Path $dir "err.txt") -NoNewWindow -PassThru
}

function Is-Running($job) { $p = Get-Process -Id ([int]$job.pid) -ErrorAction SilentlyContinue; return $p -and -not $p.HasExited -and $p.ProcessName -match "claude" }

# ---- The Tyrone thread: every job Tyrone sends goes to it, one at a time ----
function Tyrone-Prompt($t, [string]$homeDir, $notes) {
  $from = if ($t.from) { [string]$t.from } else { "you" }
  $projects = ((Get-JobFolders).Values | Sort-Object { $_.name } | ForEach-Object { "- " + $_.name + " (" + $_.path + ")" }) -join "`n"
  $running = @(Get-Subthreads | Where-Object { $_.state -eq "working" -or $_.state -eq "queued" } | ForEach-Object { "- " + $_.id + ": `"" + $_.title + "`" in " + $_.folder + " (" + $_.state + ")" }) -join "`n"
  $hint = if ($t.claude.folder) { "`nTyrone named the project: $($t.claude.folder)." } else { "" }
  $since = if (@($notes).Count) { "`nSince your last job:`n" + ((@($notes) | ForEach-Object { "- " + $_ }) -join "`n") + "`n" } else { "" }
  return @"
You are the Tyrone thread: $from's one Claude Code thread for jobs sent by Tyrone, $from's assistant, from a phone call or chat. You run in the background with no one watching, and you only dispatch: you can't see or change the projects from here. $from's projects:
$projects
$since
New job from ${from}:$hint
$($t.task)

How to work:
- Every change, however small, goes to a subthread: never edit a project yourself. One subthread is right for a job in one project; a job with separate parts gets one subthread per part, and they run at the same time, up to 5 at once (more wait their turn).
- A question you can answer from what's above (what earlier subthreads found or changed) needs no subthread: just answer it. To start one, write a file into $SpawnDir named <short-name>.json, with {"title": "a few words", "folder": "<one project name from the list>", "task": "complete instructions: the subthread knows nothing else"}. Each subthread works on its own git branch in its own copy of that project: it runs the project's checks (typecheck, tests, lint) and commits on its branch when they pass, and the relay closes it when it's done. In $(($GoLive.Keys | Sort-Object) -join ', ') the relay then puts it live by itself (merges it into main, checks it again, pushes and deploys to dev) and tells $from in the chat; in other projects it stays on its branch. Its result says its branch, how many commits, how its checks went, and whether it's going live. Never start two subthreads on the same project for parts that touch the same files.
- To stop a subthread that isn't needed any more, write $SpawnDir\stop-<its id>.json (any content).
Running or waiting subthreads now:
$(if ($running) { $running } else { "- none" })

If something you need isn't allowed or isn't clear, don't guess: say what's needed. Finish with a short plain summary (a few sentences) of what you did, which subthreads you started and why, and anything left for $from to do; Tyrone reads it to them.
"@
}

function Start-TyroneJob($key, $t) {
  $id = [string]$t.id
  $dir = Join-Path $JobsDir $id
  if (Test-Path $dir) { return }
  $null = New-Item -ItemType Directory -Force $dir
  $problem = Claude-Problem
  if (-not $problem -and -not @((Get-JobFolders).Values).Count) { $problem = "No project folders were found on this PC (where a Claude Code thread ran in the last 30 days), so there's nowhere for the work to go." }
  $homeDir = $TyroneHome
  $null = New-Item -ItemType Directory -Force $homeDir
  if ($problem) { Report $key $id "failed" $problem | Out-Null; Set-Content (Join-Path $dir "done.txt") "failed: not ready"; Log "Job $id not run: $problem"; return }
  $null = New-Item -ItemType Directory -Force $SpawnDir
  $state = Get-Tyrone
  # A session from before it moved to its own folder can't be picked up from here: start a new one (its notes carry over).
  if ($state.sessionId -and [string]$state.home -ne $homeDir) { $state.sessionId = "" }
  $state | Add-Member -Force home $homeDir
  $notes = @($state.notes)
  $extra = @("--add-dir", $SpawnDir)
  if ($state.sessionId) { $extra += @("--resume", [string]$state.sessionId) }
  $p = Start-Claude $dir $homeDir $extra (Tyrone-Prompt $t $homeDir $notes)
  $state.notes = @(); Write-Json $TyroneFile $state
  Write-Json (Join-Path $dir "job.json") @{ pid = $p.Id; started = (Get-Date).ToString("o"); where = $homeDir; task = [string]$t.task; notes = $notes; resumed = [string]$state.sessionId }
  Log "Job $id started in the Tyrone thread$(if ($state.sessionId) { '' } else { ' (a new one)' })."
  Report $key $id "working" "The Tyrone thread on your PC picked it up." | Out-Null
}

function Check-Jobs($key, $openIds) {
  foreach ($d in @(Get-ChildItem $JobsDir -Directory -ErrorAction SilentlyContinue)) {
    if (Test-Path (Join-Path $d.FullName "done.txt")) { continue }
    $job = Read-Json (Join-Path $d.FullName "job.json")
    if (-not $job) { continue }
    $running = Is-Running $job
    $age = ((Get-Date) - [DateTime]::Parse([string]$job.started)).TotalMinutes
    if ($running) { $null = Read-Stream $d.FullName }
    if ($running -and $openIds -ne $null -and -not ($openIds -contains $d.Name)) {
      Stop-Process -Id ([int]$job.pid) -Force -ErrorAction SilentlyContinue; Set-Content (Join-Path $d.FullName "done.txt") "cancelled"; Log "Job $($d.Name) cancelled."; continue
    }
    if ($running -and $age -lt $JobMinutes) { continue }
    if ($running) {
      Stop-Process -Id ([int]$job.pid) -Force -ErrorAction SilentlyContinue
      $r = @{ ok = $false; text = "The Tyrone thread was still going after $JobMinutes minutes, so the job was stopped."; session = "" }
    } else { $r = Run-Result $d.FullName }
    # The thread's session carries on to the next job. A resume that failed starts a new thread next time, with the notes it missed.
    $state = Get-Tyrone
    if ($r.session) { $state.sessionId = $r.session }
    elseif ($job.resumed -and -not $r.ok) { $state.sessionId = ""; $state.notes = @(@($job.notes) + @($state.notes)) }
    Write-Json $TyroneFile $state
    try {
      $null = Report $key $d.Name $(if ($r.ok) { "done" } else { "failed" }) $(if ($r.text.Trim()) { $r.text.Trim() } else { "Done (the Tyrone thread gave no summary)." })
      Set-Content (Join-Path $d.FullName "done.txt") $(if ($r.ok) { "done" } else { "failed" })
      Log "Job $($d.Name) $(if ($r.ok) { 'done' } else { 'failed' })."
    } catch { Log ("Job $($d.Name) result not sent yet: " + (Why $_)) }
  }
}

# ---- Subthreads: started by the Tyrone thread, up to $MaxSubthreads at once ----
function Get-Subthreads { return @(Get-ChildItem $SubDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { Read-Json (Join-Path $_.FullName "sub.json") } | Where-Object { $_ }) }
function Save-Sub($s) { Write-Json (Join-Path (Join-Path $SubDir $s.id) "sub.json") $s }
function Slug([string]$s) { $x = ($s.ToLower() -replace '[^a-z0-9]+', '-').Trim('-'); if ($x.Length -gt 30) { $x = $x.Substring(0, 30).Trim('-') }; if (-not $x) { $x = "task" }; return $x }

# Spawn files the Tyrone thread wrote: each becomes a waiting subthread; stop-<id>.json stops one.
function Take-Spawns {
  if (-not (Test-Path $SpawnDir)) { return }
  $folders = Get-JobFolders
  foreach ($f in @(Get-ChildItem $SpawnDir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
    if ($f.BaseName -like "stop-*") {
      $sid = $f.BaseName.Substring(5)
      $s = Read-Json (Join-Path (Join-Path $SubDir $sid) "sub.json")
      if ($s -and ($s.state -eq "working" -or $s.state -eq "queued")) {
        if ($s.pid) { Stop-Process -Id ([int]$s.pid) -Force -ErrorAction SilentlyContinue }
        $s.state = "stopped"; $s | Add-Member -Force finishedAt ((Get-Date).ToUniversalTime().ToString("o")); $s | Add-Member -Force result "Stopped by the Tyrone thread."; Save-Sub $s; Close-Worktree $s
        Log "Subthread $sid stopped."
      }
      Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; continue
    }
    $spec = Read-Json $f.FullName
    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
    $title = Clip ([string]$spec.title) 80; $task = [string]$spec.task; $folder = [string]$spec.folder
    $match = if ($folder) { $folders[$folder.ToLower()] } else { $null }
    if (-not $spec -or -not $title -or $task.Trim().Length -lt 10 -or -not $match) {
      Add-Note "The subthread file $($f.Name) wasn't started: it needs a title, a task, and a folder from the project list ($folder isn't one)."
      Log "Spawn file $($f.Name) skipped."; continue
    }
    $id = "st-" + ([guid]::NewGuid().ToString("N").Substring(0, 6))
    $null = New-Item -ItemType Directory -Force (Join-Path $SubDir $id)
    Save-Sub ([pscustomobject]@{ id = $id; title = $title; folder = $match.name; path = $match.path; task = $task; state = "queued"; queuedAt = (Get-Date).ToUniversalTime().ToString("o") })
    Log "Subthread $id queued: $title ($($match.name))."
  }
}

function Close-Worktree($s) {
  # Git writes notices (line endings, "Preparing worktree") to stderr; they mustn't stop the relay halfway.
  $ErrorActionPreference = "Continue"
  if (-not $s.worktree) { return }
  $wt = [string]$s.worktree
  $leftover = $false
  if (Test-Path -LiteralPath $wt) {
    # Anything the subthread didn't commit itself (its checks didn't pass, or it stopped) is still kept on its branch, marked as such.
    if (@(& git -C $wt status --porcelain 2>$null).Count) {
      & git -C $wt add -A 2>$null | Out-Null
      & git -C $wt commit -q -m "Tyrone subthread (not committed by it; checks may not pass): $($s.title)" 2>$null | Out-Null
      $leftover = $true
    }
    & git -C ([string]$s.path) worktree remove --force $wt 2>$null | Out-Null
  }
  $ahead = [int](& git -C ([string]$s.path) rev-list --count "$($s.base)..$($s.branch)" 2>$null)
  $s | Add-Member -Force commits $ahead
  $s | Add-Member -Force leftover $leftover
  if ($ahead -gt 0) { $s | Add-Member -Force kept $true } else { & git -C ([string]$s.path) branch -D ([string]$s.branch) 2>$null | Out-Null; $s | Add-Member -Force kept $false }
  Save-Sub $s
}

function Start-Sub($s) {
  $ErrorActionPreference = "Continue"
  $dir = Join-Path $SubDir $s.id
  $where = [string]$s.path
  if (Test-Path -LiteralPath (Join-Path $where ".git")) {
    $branch = "tyrone/" + (Slug $s.title) + "-" + $s.id.Substring(3)
    # Inside the project (.claude\worktrees, as the Claude app does it), so its checks find the project's installed packages by walking up.
    $wt = Join-Path $where ".claude\worktrees\tyrone-$($s.id.Substring(3))"
    $base = (& git -C $where rev-parse HEAD 2>$null | Out-String).Trim()
    & git -C $where worktree add -q $wt -b $branch 2>$null | Out-Null
    if (-not (Test-Path -LiteralPath $wt)) { $s.state = "failed"; $s | Add-Member -Force result "Its own copy of $($s.folder) couldn't be made (git worktree), so it didn't start."; $s | Add-Member -Force finishedAt ((Get-Date).ToUniversalTime().ToString("o")); Save-Sub $s; Add-Note "Subthread `"$($s.title)`" ($($s.folder)) failed: $($s.result)"; return }
    $s | Add-Member -Force worktree $wt; $s | Add-Member -Force branch $branch; $s | Add-Member -Force base $base
    $where = $wt
  }
  $prompt = @"
You are a subthread of the Tyrone thread, running in the background with no one watching. Do this in the $($s.folder) project$(if ($s.branch) { " (your own copy of it, on the branch $($s.branch))" }):

$($s.task)

Work only in this folder.$(if ($s.branch) { @"

When the change is made, run the project's checks: its typecheck and unit tests (see the scripts in package.json, or pytest), and its linter if it has one. Fix what they catch and run them again until they pass. Then commit on your branch (git add, then git commit with a short message saying what changed). Commit only when the checks pass; if they can't pass, don't commit, and say what fails and why. You may run only those checks and git status, diff, log, show, add and commit: never push, merge, switch branches, deploy or delete anything.
"@ })
If something you need isn't allowed or isn't clear, don't guess: stop and say what's needed. Finish with a short plain summary (a few sentences) of what you did, what changed, which checks you ran and whether they passed, and whether you committed.
"@
  $p = Start-Claude $dir $where $(if ($s.branch) { @("--allowedTools") + $SubthreadTools } else { @() }) $prompt
  $s.state = "working"; $s | Add-Member -Force pid $p.Id; $s | Add-Member -Force startedAt ((Get-Date).ToUniversalTime().ToString("o")); Save-Sub $s
  Log "Subthread $($s.id) started in $where."
}

function Check-Subs {
  Take-Spawns
  $all = Get-Subthreads
  foreach ($s in @($all | Where-Object { $_.state -eq "working" })) {
    $dir = Join-Path $SubDir $s.id
    $running = Is-Running $s
    if ($running) { $null = Read-Stream $dir }
    $age = ((Get-Date).ToUniversalTime() - [DateTime]::Parse([string]$s.startedAt).ToUniversalTime()).TotalMinutes
    if ($running -and $age -lt $JobMinutes) { continue }
    if ($running) { Stop-Process -Id ([int]$s.pid) -Force -ErrorAction SilentlyContinue; $r = @{ ok = $false; text = "Still going after $JobMinutes minutes, so it was stopped." } } else { $r = Run-Result $dir }
    $s.state = $(if ($r.ok) { "done" } else { "failed" }); $s | Add-Member -Force finishedAt ((Get-Date).ToUniversalTime().ToString("o"))
    Close-Worktree $s
    $where = if ($s.branch) { if ($s.kept) { " Branch $($s.branch) in $($s.folder): $($s.commits) commit$(if ($s.commits -ne 1) { 's' }).$(if ($s.leftover) { ' The last one holds changes it didn''t commit itself, so its checks may not pass, and it won''t go live.' })" } else { " It changed no files." } } else { "" }
    if ($s.state -eq "done" -and $s.kept -and -not $s.leftover) {
      $g = $GoLive[([string]$s.folder).ToLower()]
      if ($g) { Write-Json (Join-Path $dir "ship.json") ([pscustomobject]@{ state = "waiting"; steps = @(); detail = "Waiting to go live" }); $where += " Going live on $($g.branch) next: the relay merges it into main, runs the checks again, pushes and deploys." }
      else { $where += " $($s.folder) has no go-live steps set up, so it stays on its branch." }
    }
    $s | Add-Member -Force result ((Clip $r.text 2500) + $where)
    Save-Sub $s
    Add-Note "Subthread $($s.id) `"$($s.title)`" ($($s.folder)) $($s.state): $(Clip $r.text 1200)$where"
    Log "Subthread $($s.id) $($s.state)."
  }
  Check-Ships
  # Waiting ones start as places free up; a project with no git gets one subthread at a time.
  $working = @(Get-Subthreads | Where-Object { $_.state -eq "working" })
  foreach ($s in @(Get-Subthreads | Where-Object { $_.state -eq "queued" } | Sort-Object { [string]$_.queuedAt })) {
    if ($working.Count -ge $MaxSubthreads) { break }
    if (-not (Test-Path -LiteralPath (Join-Path ([string]$s.path) ".git")) -and @($working | Where-Object { $_.path -eq $s.path }).Count) { continue }
    if (Claude-Problem) { break }
    Start-Sub $s
    $working += $s
  }
  # Finished subthreads go after a week.
  foreach ($s in @(Get-Subthreads | Where-Object { $_.finishedAt -and ((Get-Date).ToUniversalTime() - [DateTime]::Parse([string]$_.finishedAt).ToUniversalTime()).TotalDays -gt 7 })) { Remove-Item -Recurse -Force (Join-Path $SubDir $s.id) -ErrorAction SilentlyContinue }
}

# ---- Going live: run by the relay, one project at a time, in its own hidden PowerShell (-Ship <id>) ----
function Ship-File([string]$sid, [string]$name) { return Join-Path (Join-Path $SubDir $sid) $name }
function Ship-Step([string]$sid, [string]$state, [string]$text, [string]$commit = "") {
  $file = Ship-File $sid "ship.json"
  $g = Read-Json $file; if (-not $g) { $g = [pscustomobject]@{ state = $state; steps = @() } }
  $g.state = $state
  if ($text) { $g.steps = @(@($g.steps) + @([pscustomobject]@{ at = (Get-Date).ToUniversalTime().ToString("o"); text = (Clip $text 200) }) | Select-Object -Last 10); $g | Add-Member -Force detail (Clip $text 1500) }
  if ($commit) { $g | Add-Member -Force commit $commit }
  Write-Json $file $g
  Log "Going live, ${sid}: $(Clip $text 300)"
}

function Run-Ship([string]$sid) {
  $ErrorActionPreference = "Continue"
  $s = Read-Json (Ship-File $sid "sub.json")
  if (-not $s) { return }
  $g = $GoLive[([string]$s.folder).ToLower()]
  if (-not $g) { Ship-Step $sid "failed" "$($s.folder) has no go-live steps."; return }
  $repo = [string]$s.path; $branch = [string]$s.branch
  $wt = Join-Path $repo ".claude\worktrees\tyrone-live-$($sid.Substring(3))"
  try {
    Ship-Step $sid "going" "Getting the latest $($s.folder) from GitHub"
    & git -C $repo fetch -q origin 2>$null | Out-Null
    if ($LASTEXITCODE) { throw "Couldn't reach GitHub (git fetch failed), so it isn't live. It's still on $branch." }
    if (Test-Path -LiteralPath $wt) { & git -C $repo worktree remove --force $wt 2>$null | Out-Null }
    & git -C $repo worktree add -q --detach $wt origin/main 2>$null | Out-Null
    if (-not (Test-Path -LiteralPath $wt)) { throw "Couldn't make a copy of main to merge into, so it isn't live. It's still on $branch." }
    Ship-Step $sid "going" "Merging $branch into main"
    foreach ($from in @($branch, "origin/$($g.branch)")) {
      $null = (& git -C $wt merge --no-edit -m "Merge $from (Tyrone: $($s.title))" $from 2>&1 | Out-String)
      if ($LASTEXITCODE) {
        $files = @(& git -C $wt diff --name-only --diff-filter=U 2>$null) -join ", "
        & git -C $wt merge --abort 2>$null | Out-Null
        throw "It clashes with newer changes on $(if ($from -eq $branch) { 'main' } else { $g.branch })$(if ($files) { " in $files" }), so it wasn't merged or pushed. It's still on $branch."
      }
    }
    foreach ($c in @($g.checks | Where-Object { $_ })) {
      Ship-Step $sid "going" "Running $c on the merged code"
      Push-Location -LiteralPath $wt
      try { $out = (& cmd.exe /c "$c 2>&1" | Out-String); $code = $LASTEXITCODE } finally { Pop-Location }
      if ($code) { throw "$c failed on the merged code, so nothing was pushed. It's still on $branch. The end of its output: $(Clip ((@($out -split "`n" | Where-Object { $_.Trim() }) | Select-Object -Last 12) -join ' | ') 700)" }
    }
    $commit = (& git -C $wt rev-parse HEAD 2>$null | Out-String).Trim()
    $h8 = $commit.Substring(0, 8)
    Ship-Step $sid "going" "Pushing $h8 to main and $($g.branch)" $commit
    $out = (& git -C $wt push -q origin "HEAD:refs/heads/main" "HEAD:refs/heads/$($g.branch)" 2>&1 | Out-String)
    if ($LASTEXITCODE) { throw "GitHub refused the push (someone may have pushed at the same moment), so it isn't live. It's still on $branch. $(Clip $out 300)" }
    if (-not $g.host) { Ship-Step $sid "live" "Pushed $h8 to main and $($g.branch)." $commit; return }
    Ship-Step $sid "going" "Deploying $h8 to $($g.branch)"
    $out = (& ssh -o BatchMode=yes -o ConnectTimeout=15 $g.host $g.deploy 2>&1 | Out-String)
    if ($LASTEXITCODE) { throw "It's pushed to main and $($g.branch) ($h8), but the deploy couldn't start: $(Clip $out 300)" }
    $until = (Get-Date).AddMinutes($GoLiveMinutes)
    while ((Get-Date) -lt $until) {
      $st = (& ssh -o BatchMode=yes -o ConnectTimeout=15 $g.host $g.status 2>&1 | Out-String)
      if (@($st -split "`n" | Where-Object { $_ -match "^\s*$([regex]::Escape($g.app))\s" -and $_ -match "$h8 live" }).Count) { Ship-Step $sid "live" "Live on $($g.branch): $h8." $commit; return }
      Start-Sleep -Seconds 20
    }
    Ship-Step $sid "failed" "Pushed $h8 to main and $($g.branch) and started the deploy, but it didn't show as live within $GoLiveMinutes minutes. Check ltg-dev-deploy status." $commit
  } catch {
    Ship-Step $sid "failed" ([string]$_.Exception.Message)
  } finally {
    if (Test-Path -LiteralPath $wt) { & git -C $repo worktree remove --force $wt 2>$null | Out-Null }
  }
}

# Starts waiting ones (one per project at a time), notices one that died, and tells the Tyrone thread how each ended.
function Check-Ships {
  $all = @(Get-Subthreads)
  foreach ($s in $all) {
    $g = Read-Json (Ship-File $s.id "ship.json")
    if (-not $g) { continue }
    $pidFile = Ship-File $s.id "ship.pid"
    $alive = $false
    if (Test-Path -LiteralPath $pidFile) { $p = Get-Process -Id ([int](Get-Content -LiteralPath $pidFile -Raw)) -ErrorAction SilentlyContinue; $alive = $p -and -not $p.HasExited -and $p.ProcessName -match "powershell" }
    if (($g.state -eq "going" -or $g.state -eq "waiting") -and (Test-Path -LiteralPath $pidFile) -and -not $alive) { Ship-Step $s.id "failed" "The go-live step stopped partway (the PC may have restarted). It's still on $($s.branch)."; $g = Read-Json (Ship-File $s.id "ship.json") }
    if ($g.state -eq "waiting" -and -not (Test-Path -LiteralPath $pidFile)) {
      $busy = @($all | Where-Object { $_.id -ne $s.id -and $_.path -eq $s.path -and (Test-Path -LiteralPath (Ship-File $_.id "ship.pid")) -and @("waiting", "going") -contains [string](Read-Json (Ship-File $_.id "ship.json")).state }).Count
      if ($busy) { continue }
      $p = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Ship $($s.id)" -WindowStyle Hidden -PassThru
      Set-Content -LiteralPath $pidFile -Value $p.Id
      Log "Subthread $($s.id) going live."
    }
    if (($g.state -eq "live" -or $g.state -eq "failed") -and -not (Test-Path -LiteralPath (Ship-File $s.id "ship.told"))) {
      Add-Note "Subthread $($s.id) `"$($s.title)`" ($($s.folder)) $(if ($g.state -eq 'live') { 'went live' } else { "didn't go live" }): $($g.detail)"
      Set-Content -LiteralPath (Ship-File $s.id "ship.told") -Value $g.state
    }
  }
}

# ---- Live: what the Tyrone thread and its subthreads are doing, step by step, for Talk ----
function Live-Body {
  $job = $null
  foreach ($d in @(Get-ChildItem $JobsDir -Directory -ErrorAction SilentlyContinue)) {
    if (Test-Path (Join-Path $d.FullName "done.txt")) { continue }
    $j = Read-Json (Join-Path $d.FullName "job.json")
    if ($j -and (Is-Running $j)) { $st = Read-Stream $d.FullName; $job = @{ id = $d.Name; task = (Clip ([string]$j.task) 300); startedAt = ([DateTime]::Parse([string]$j.started)).ToUniversalTime().ToString("o"); steps = @($st.steps | Select-Object -Last 10) } }
  }
  $day = (Get-Date).ToUniversalTime().AddHours(-24)
  $subs = @(Get-Subthreads | Where-Object { $_.state -eq "queued" -or $_.state -eq "working" -or ($_.finishedAt -and [DateTime]::Parse([string]$_.finishedAt).ToUniversalTime() -gt $day) -or (Test-Path -LiteralPath (Ship-File $_.id "ship.pid")) -and -not (Test-Path -LiteralPath (Ship-File $_.id "ship.told")) } | ForEach-Object {
    $st = if ($_.state -eq "working") { Read-Stream (Join-Path $SubDir $_.id) } else { $null }
    $o = [ordered]@{ id = $_.id; title = $_.title; folder = $_.folder; state = $_.state }
    foreach ($k in "queuedAt", "startedAt", "finishedAt", "branch", "result") { if ($_.$k) { $o[$k] = [string]$_.$k } }
    if ($st) { $o.steps = @($st.steps | Select-Object -Last 6) }
    $g = Read-Json (Ship-File $_.id "ship.json")
    if ($g) { $o.ship = [ordered]@{ state = [string]$g.state; detail = [string]$g.detail; steps = @($g.steps | Select-Object -Last 6) }; if ($g.commit) { $o.ship.commit = [string]$g.commit } }
    $o
  })
  return @{ tyrone = @{ version = $Version; state = $(if ($job) { "working" } else { "idle" }); job = $job; subthreads = $subs; max = $MaxSubthreads } }
}

$script:LastLive = ""; $script:LastLiveAt = [DateTime]::MinValue
# Sent when anything changed, and at least every two minutes so the app knows the relay is up.
function Send-Live([string]$key) {
  $body = ConvertTo-Json -InputObject (Live-Body) -Depth 8 -Compress
  if ($body -eq $script:LastLive -and ((Get-Date) - $script:LastLiveAt).TotalSeconds -lt 120) { return }
  $web = Web $key; $web.Headers["Content-Type"] = "application/json"
  [void]$web.UploadString($LiveUrl, "POST", $body)
  $script:LastLive = $body; $script:LastLiveAt = Get-Date
}

function Busy { return [bool]((@(Get-ChildItem $JobsDir -Directory -ErrorAction SilentlyContinue | Where-Object { -not (Test-Path (Join-Path $_.FullName "done.txt")) -and (Test-Path (Join-Path $_.FullName "job.json")) }).Count) -or @(Get-Subthreads | Where-Object { $_.state -eq "working" -or $_.state -eq "queued" -or @("waiting", "going") -contains [string](Read-Json (Ship-File $_.id "ship.json")).state }).Count) }

function Poll-Jobs([string]$key) {
  $null = New-Item -ItemType Directory -Force $JobsDir, $SubDir, $WtDir, $SpawnDir
  $tasks = @(((Web $key).DownloadString($TasksUrl) | ConvertFrom-Json).tasks)
  $open = @($tasks | ForEach-Object { [string]$_.id })
  Check-Jobs $key $open
  # One Tyrone job at a time: the next one starts when it's free.
  $running = @(Get-ChildItem $JobsDir -Directory -ErrorAction SilentlyContinue | Where-Object { (Test-Path (Join-Path $_.FullName "job.json")) -and -not (Test-Path (Join-Path $_.FullName "done.txt")) }).Count
  if (-not $running) {
    $next = $tasks | Where-Object { $_.claude -and -not (Test-Path (Join-Path $JobsDir ([string]$_.id))) } | Select-Object -First 1
    if ($next) { Start-TyroneJob $key $next }
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
  # A running older copy stops first, so the new one takes over.
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
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
  Write-Host ("The Tyrone thread works in: $TyroneHome (outside your projects: every change goes to a subthread, on its own branch)")
  $ty = Get-Tyrone
  Write-Host ("Tyrone thread session: " + $(if ($ty.sessionId) { $ty.sessionId } else { "not started yet (the first job starts it)" }))
  Write-Host "Projects it and its subthreads can work on (where a Claude Code thread ran in the last 30 days):"
  (Get-JobFolders).Values | Sort-Object { $_.name } | ForEach-Object { Write-Host ("  " + $_.name + "  " + $_.path) }
  exit 0
}

if ($DryRun) { ConvertTo-Json -InputObject @{ threads = @(Get-Threads); folders = @((Get-JobFolders).Values | ForEach-Object { $_.name } | Sort-Object) } -Depth 4; exit 0 }

# -Ship <subthread id>: the relay starts this, hidden, to put one finished subthread live.
if ($Ship) { Run-Ship $Ship; exit 0 }

$key = Get-Key
if (-not $key) { Write-Host "Not connected yet: run ClaudeRelay.ps1 -Connect" -ForegroundColor Yellow; exit 1 }
if ($Once) { try { Log (Send-Threads $key); exit 0 } catch { Log ("Not sent: " + (Why $_)); exit 1 } }

# One relay at a time.
$mutex = New-Object System.Threading.Mutex($false, "Local\ClaudeRelay")
if (-not $mutex.WaitOne(0)) { Write-Host "The Claude relay is already running." -ForegroundColor Yellow; exit 0 }
Log "Claude relay $Version running: sending your threads every two minutes, jobs to the Tyrone thread (up to $MaxSubthreads subthreads), live steps while anything runs."
$lastNote = ""; $lastJobNote = ""; $lastLiveNote = ""; $nextThreads = Get-Date; $nextJobs = Get-Date
while ($true) {
  $key = Get-Key
  if ((Get-Date) -ge $nextThreads) {
    $note = if (-not $key) { "Not connected: run ClaudeRelay.ps1 -Connect" } else { try { Send-Threads $key } catch { "Not sent: " + (Why $_) } }
    # The log gets a line when something changes, not every two minutes.
    if ($note -ne $lastNote) { Log $note; $lastNote = $note }
    $nextThreads = (Get-Date).AddMinutes(2)
  }
  if ($key) {
    if ((Get-Date) -ge $nextJobs) {
      $jobNote = try { Poll-Jobs $key; "" } catch { "Jobs not checked: " + (Why $_) }
      if ($jobNote -ne $lastJobNote) { if ($jobNote) { Log $jobNote }; $lastJobNote = $jobNote }
      $nextJobs = (Get-Date).AddSeconds(20)
    }
    $liveNote = try { Check-Subs; Send-Live $key; "" } catch { "Live not sent: " + (Why $_) }
    if ($liveNote -ne $lastLiveNote) { if ($liveNote) { Log $liveNote }; $lastLiveNote = $liveNote }
  }
  # Every few seconds while anything runs, so Talk shows each step; every 20 seconds otherwise.
  Start-Sleep -Seconds $(if (Busy) { 3 } else { 20 })
}
