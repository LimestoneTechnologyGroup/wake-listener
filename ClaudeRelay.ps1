# Claude relay: Smokey and your Claude Code threads.
#
# Run it on the PC where the Claude desktop app runs your Claude Code threads
# (not necessarily the one with the wake listener). It does two things:
#
# 1. Every two minutes it reads the desktop app's session files on this PC
#    (each thread's name, folder, whether it's working or done, its last report,
#    anything it needs from you) and sends that list to Project Check-in with its
#    own key, so "what's going on in my threads?" gets an answer.
# 2. Every Claude Code job Smokey sends goes to one Smokey thread: a Claude
#    Code session on this PC, picked up again for each job (one at a time), so
#    it remembers what came before. It works in its own folder, outside your
#    projects, and only dispatches: every change, however small, goes to a
#    subthread (up to 5 run at once), each in its own git worktree of one
#    project, on its own branch (smokey/...; tyrone/... before 4.3), committed by the relay when it
#    finishes and then closed. Nothing ever lands on the branch you work on.
#    File edits are allowed; any command your project hasn't allowed is
#    refused. Results go back to Smokey and your chat. Claude Code here needs
#    signing in once: see -Doctor.
#    Going live (3.3.0): when a subthread's checks pass in a project with
#    go-live steps below ($GoLive), the relay itself (not Claude) merges its
#    branch into main, runs the checks again on the merged code, pushes main
#    and dev, and deploys, posting each step to your Smokey chat and Talk.
# 3. While anything runs, every few seconds it sends what the Smokey thread and
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
param([switch]$Connect, [switch]$Doctor, [switch]$DryRun, [switch]$Once, [switch]$Install, [switch]$Uninstall, [switch]$Branches, [string]$Ship = "", [string]$Undo = "", [string]$Base = "https://project-checkin.dev.limestonetg.com")

$ErrorActionPreference = "Stop"
$Version = "4.4.0"
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
$SmokeyFile = Join-Path $Folder "smokey.json"
# Before 4.3 (the assistant was Tyrone) its state was tyrone.json: picked up once, so the thread carries on.
$OldStateFile = Join-Path $Folder "tyrone.json"
if (-not (Test-Path -LiteralPath $SmokeyFile) -and (Test-Path -LiteralPath $OldStateFile)) { Copy-Item -LiteralPath $OldStateFile $SmokeyFile }
# The Smokey thread works here, outside every project: it can't change a project itself, so every change goes on a branch.
# A relay from before 4.3 made it as "tyrone"; that folder stays in use, because Claude Code finds a thread's
# session by the folder it ran in, and a new folder would start the thread afresh.
$SmokeyHome = if (Test-Path -LiteralPath (Join-Path $Folder "tyrone")) { Join-Path $Folder "tyrone" } else { Join-Path $Folder "smokey" }
# Branches made before 4.3 keep their tyrone/... names and are still followed. New ones are smokey/... once the app
# is agreed to take them (BranchPrefix); the copies (worktrees) are local, so new ones are smokey- already.
$BranchPrefix = "tyrone"
$BranchPrefixes = @("smokey", "tyrone")
$CopyPrefix = "smokey"
# A subthread's copy of its project (or a go-live or undo copy): the one already there under either name, else a new smokey- one.
function Wt-Path([string]$repo, [string]$kind, [string]$sid) {
  $tail = $(if ($kind) { "$kind-" } else { "" }) + $sid.Substring(3)
  foreach ($p in $BranchPrefixes) { $wt = Join-Path $repo ".claude\worktrees\$p-$tail"; if (Test-Path -LiteralPath $wt) { return $wt } }
  return Join-Path $repo ".claude\worktrees\$CopyPrefix-$tail"
}
$MaxSubthreads = 5
# What a subthread may run without asking (Zack, 2026-11-26): its project's checks, and committing on its own
# branch. Never push, deploy, switch branches or delete: anything else is refused.
$CheckCommands = @("npm run test", "npm run typecheck", "npm run lint", "npm run check", "npm test", "npx tsc", "npx vitest", "npx eslint", "npx playwright test", "node --check", "python -m pytest", "pytest", "python -m unittest", "py -m pytest", "py -m unittest", "python -m py_compile", "git status", "git diff", "git log", "git show", "git add", "git commit")
$SubthreadTools = @($CheckCommands | ForEach-Object { "Bash($($_):*)"; "PowerShell($($_):*)" })
$JobMinutes = 45
# Going live (Zack, 2026-11-26: "push all the way to dev, if I can see it in the chat"). A subthread that committed
# with its checks passing, in one of these projects, is merged into main, checked again, pushed to main and the
# deploy branch, and deployed, by the relay itself: subthreads still can't push. Other projects stay on their branch.
# host/deploy/status are left out for a project that deploys on push. CLAUDE_RELAY_GOLIVE (a JSON file) is for testing.
$GoLive = @{
  # officepet deploys itself when main is pushed (GitHub Actions: tests, build, deploy to 865Apps).
  "officepet" = @{ branch = "main"; checks = @("python -m unittest discover -s tests") }
  "project-checkin" = @{ branch = "dev"; checks = @("npm run typecheck", "npm test"); host = "zack@162.35.15.207"; deploy = "sudo -n ltg-dev-deploy run project-checkin"; status = "sudo -n ltg-dev-deploy status project-checkin"; app = "project-checkin" }
}
if ($env:CLAUDE_RELAY_GOLIVE) { $GoLive = @{}; foreach ($p in (Get-Content $env:CLAUDE_RELAY_GOLIVE -Raw | ConvertFrom-Json).PSObject.Properties) { $GoLive[$p.Name.ToLower()] = @{ branch = $p.Value.branch; checks = @($p.Value.checks); host = $p.Value.host; deploy = $p.Value.deploy; status = $p.Value.status; app = $p.Value.app } } }
$GoLiveMinutes = 20
# Smokey building himself (4.0): a build waiting on an answer keeps its copy for this long, then is parked on its branch.
$AskHours = 24
$BuildFolder = "project-checkin"
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

# ---- Claude Code jobs from Smokey: one Smokey thread, and its subthreads ----
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
# Runs one check in the current folder and returns its output as plain text. Node and Python
# write UTF-8, so it's read as UTF-8 (the console's code page turned "…" into "ΓÇª"), and
# colour codes and rule lines are dropped, so a failure reads cleanly in the chat.
# $LASTEXITCODE is left as the check's.
function Run-Check([string]$c) {
  $savedEnc = $null
  try { $savedEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
  try { $out = (& cmd.exe /c "$c 2>&1" | Out-String); $code = $LASTEXITCODE } finally { if ($savedEnc) { try { [Console]::OutputEncoding = $savedEnc } catch { } } }
  $out = $out -replace '\x1b\[[0-9;?]*[A-Za-z]', '' -replace '[\u2500-\u257F\u23AF\u276F]+', ' '
  $global:LASTEXITCODE = $code
  return $out
}

# The useful part of a failed check for the chat: the failing tests and errors when it names
# them (vitest, unittest, tsc), otherwise its last lines.
function Check-Failure([string]$out) {
  $lines = @($out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $key = @($lines | Where-Object { $_ -match '^(FAIL|ERROR|FAILED)\b|AssertionError|\berror TS\d+|^Error:|^Expected|^Received|Test Files|^Tests\s' } | Select-Object -First 10)
  if (-not $key.Count) { $key = @($lines | Select-Object -Last 12) }
  return (Clip ($key -join ' | ') 700)
}

function Clip([string]$s, [int]$max) { $s = ($s -replace '\s+', ' ').Trim(); if ($s.Length -gt $max) { return $s.Substring(0, $max).TrimEnd() + "…" }; return $s }

# The Smokey thread's state: its Claude Code session, and notes for its next job (subthreads that finished since).
function Get-Smokey { $t = Read-Json $SmokeyFile; if (-not $t) { $t = [pscustomobject]@{ sessionId = ""; notes = @() } }; if (-not $t.notes) { $t | Add-Member -Force notes @() }; return $t }
function Add-Note([string]$text) { $t = Get-Smokey; $t.notes = @(@($t.notes) + $text | Select-Object -Last 20); Write-Json $SmokeyFile $t }

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

# The project's own tools first on the PATH (its .venv's Python, its node_modules\.bin), found by walking up from
# where it runs (a worktree sits inside its project), so "python -m unittest" or "npm test" runs as it does for them.
# The caller saves and restores $env:PATH and $env:VIRTUAL_ENV.
function Use-ProjectTools([string]$where) {
  $first = @(); $at = $where; $venvSet = $false
  while ($at) {
    $venv = Join-Path $at ".venv"
    if (-not $venvSet -and (Test-Path (Join-Path $venv "Scripts\python.exe"))) { $first += (Join-Path $venv "Scripts"); $env:VIRTUAL_ENV = $venv; $venvSet = $true }
    $bin = Join-Path $at "node_modules\.bin"
    if ((Test-Path $bin) -and -not ($first -contains $bin)) { $first += $bin }
    $up = Split-Path $at -Parent; if (-not $up -or $up -eq $at) { break }; $at = $up
  }
  if ($first.Count) { $env:PATH = (($first | Select-Object -Unique) -join ";") + ";" + $env:PATH }
}

# A worktree has the project's files but not its installed packages. Checks that name node_modules by path
# (project-checkin's promote test runs node_modules/tsx) fail there, so the copy gets a junction to the
# project's own node_modules, removed again before the worktree is (so removing it never touches the real one).
function Link-Packages([string]$repo, [string]$wt) {
  $src = Join-Path $repo "node_modules"; $dst = Join-Path $wt "node_modules"
  if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) { & cmd.exe /c "mklink /J `"$dst`" `"$src`"" 2>$null | Out-Null }
}
# Removes the junction only. True when nothing linked is left, so the worktree can be removed safely.
function Unlink-Packages([string]$wt) {
  $dst = Join-Path $wt "node_modules"
  $item = Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
  if (-not $item) { return $true }
  if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $true }
  & cmd.exe /c "rmdir `"$dst`"" 2>$null | Out-Null
  return -not (Test-Path -LiteralPath $dst)
}
function Remove-Worktree([string]$repo, [string]$wt) {
  if (-not (Test-Path -LiteralPath $wt)) { return }
  if (Unlink-Packages $wt) { & git -C $repo worktree remove --force $wt 2>$null | Out-Null } else { Log "Left $wt in place: its node_modules link couldn't be removed." }
}

function Start-Claude([string]$dir, [string]$where, [string[]]$extra, [string]$prompt) {
  [IO.File]::WriteAllText((Join-Path $dir "prompt.txt"), $prompt, (New-Object Text.UTF8Encoding($false)))
  $cliArgs = @("-p", "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits") + $extra
  # PowerShell 5.1 joins ArgumentList with spaces and no quoting: anything with a space ("Bash(npm test:*)") is quoted here.
  $line = ($cliArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join " "
  $savedPath = $env:PATH; $savedVenv = $env:VIRTUAL_ENV
  try {
    Use-ProjectTools $where
    return Start-Process -FilePath (Find-Claude) -ArgumentList $line -WorkingDirectory $where -RedirectStandardInput (Join-Path $dir "prompt.txt") -RedirectStandardOutput (Join-Path $dir "out.json") -RedirectStandardError (Join-Path $dir "err.txt") -NoNewWindow -PassThru
  } finally { $env:PATH = $savedPath; $env:VIRTUAL_ENV = $savedVenv }
}

function Is-Running($job) { $p = Get-Process -Id ([int]$job.pid) -ErrorAction SilentlyContinue; return $p -and -not $p.HasExited -and $p.ProcessName -match "claude" }

# ---- The Smokey thread: every job Smokey sends goes to it, one at a time ----
function Smokey-Prompt($t, [string]$homeDir, $notes) {
  $from = if ($t.from) { [string]$t.from } else { "you" }
  $projects = ((Get-JobFolders).Values | Sort-Object { $_.name } | ForEach-Object { "- " + $_.name + " (" + $_.path + ")" }) -join "`n"
  $running = @(Get-Subthreads | Where-Object { $_.state -eq "working" -or $_.state -eq "queued" } | ForEach-Object { "- " + $_.id + ": `"" + $_.title + "`" in " + $_.folder + " (" + $_.state + ")" }) -join "`n"
  $hint = if ($t.claude.folder) { "`nSmokey named the project: $($t.claude.folder)." } else { "" }
  $since = if (@($notes).Count) { "`nSince your last job:`n" + ((@($notes) | ForEach-Object { "- " + $_ }) -join "`n") + "`n" } else { "" }
  return @"
You are the Smokey thread: $from's one Claude Code thread for jobs sent by Smokey, $from's assistant, from a phone call or chat. You run in the background with no one watching, and you only dispatch: you can't see or change the projects from here. $from's projects:
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

If something you need isn't allowed or isn't clear, don't guess: say what's needed. Finish with a short plain summary (a few sentences) of what you did, which subthreads you started and why, and anything left for $from to do; Smokey reads it to them.
"@
}

function Start-SmokeyJob($key, $t) {
  $id = [string]$t.id
  $dir = Join-Path $JobsDir $id
  if (Test-Path $dir) { return }
  $null = New-Item -ItemType Directory -Force $dir
  $problem = Claude-Problem
  if (-not $problem -and -not @((Get-JobFolders).Values).Count) { $problem = "No project folders were found on this PC (where a Claude Code thread ran in the last 30 days), so there's nowhere for the work to go." }
  $homeDir = $SmokeyHome
  $null = New-Item -ItemType Directory -Force $homeDir
  if ($problem) { Report $key $id "failed" $problem | Out-Null; Set-Content (Join-Path $dir "done.txt") "failed: not ready"; Log "Job $id not run: $problem"; return }
  $null = New-Item -ItemType Directory -Force $SpawnDir
  $state = Get-Smokey
  # A session from before it moved to its own folder can't be picked up from here: start a new one (its notes carry over).
  if ($state.sessionId -and [string]$state.home -ne $homeDir) { $state.sessionId = "" }
  $state | Add-Member -Force home $homeDir
  $notes = @($state.notes)
  $extra = @("--add-dir", $SpawnDir)
  if ($state.sessionId) { $extra += @("--resume", [string]$state.sessionId) }
  $p = Start-Claude $dir $homeDir $extra (Smokey-Prompt $t $homeDir $notes)
  $state.notes = @(); Write-Json $SmokeyFile $state
  Write-Json (Join-Path $dir "job.json") @{ pid = $p.Id; started = (Get-Date).ToString("o"); where = $homeDir; task = [string]$t.task; notes = $notes; resumed = [string]$state.sessionId }
  Log "Job $id started in the Smokey thread$(if ($state.sessionId) { '' } else { ' (a new one)' })."
  Report $key $id "working" "The Smokey thread on your PC picked it up." | Out-Null
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
      $r = @{ ok = $false; text = "The Smokey thread was still going after $JobMinutes minutes, so the job was stopped."; session = "" }
    } else { $r = Run-Result $d.FullName }
    # The thread's session carries on to the next job. A resume that failed starts a new thread next time, with the notes it missed.
    $state = Get-Smokey
    if ($r.session) { $state.sessionId = $r.session }
    elseif ($job.resumed -and -not $r.ok) { $state.sessionId = ""; $state.notes = @(@($job.notes) + @($state.notes)) }
    Write-Json $SmokeyFile $state
    try {
      $null = Report $key $d.Name $(if ($r.ok) { "done" } else { "failed" }) $(if ($r.text.Trim()) { $r.text.Trim() } else { "Done (the Smokey thread gave no summary)." })
      Set-Content (Join-Path $d.FullName "done.txt") $(if ($r.ok) { "done" } else { "failed" })
      Log "Job $($d.Name) $(if ($r.ok) { 'done' } else { 'failed' })."
    } catch { Log ("Job $($d.Name) result not sent yet: " + (Why $_)) }
  }
}

# ---- Subthreads: started by the Smokey thread, up to $MaxSubthreads at once ----
function Get-Subthreads { return @(Get-ChildItem $SubDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { Read-Json (Join-Path $_.FullName "sub.json") } | Where-Object { $_ }) }
function Save-Sub($s) { Write-Json (Join-Path (Join-Path $SubDir $s.id) "sub.json") $s }
function Slug([string]$s) { $x = ($s.ToLower() -replace '[^a-z0-9]+', '-').Trim('-'); if ($x.Length -gt 30) { $x = $x.Substring(0, 30).Trim('-') }; if (-not $x) { $x = "task" }; return $x }

# Spawn files the Smokey thread wrote: each becomes a waiting subthread; stop-<id>.json stops one.
function Take-Spawns {
  if (-not (Test-Path $SpawnDir)) { return }
  $folders = Get-JobFolders
  foreach ($f in @(Get-ChildItem $SpawnDir -Filter "*.json" -File -ErrorAction SilentlyContinue)) {
    if ($f.BaseName -like "stop-*") {
      $sid = $f.BaseName.Substring(5)
      $s = Read-Json (Join-Path (Join-Path $SubDir $sid) "sub.json")
      if ($s -and ($s.state -eq "working" -or $s.state -eq "queued")) {
        if ($s.pid) { Stop-Process -Id ([int]$s.pid) -Force -ErrorAction SilentlyContinue }
        $s.state = "stopped"; $s | Add-Member -Force finishedAt ((Get-Date).ToUniversalTime().ToString("o")); $s | Add-Member -Force result "Stopped by the Smokey thread."; Save-Sub $s; Close-Worktree $s
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

function Close-Worktree($s, [bool]$discard = $false) {
  # Git writes notices (line endings, "Preparing worktree") to stderr; they mustn't stop the relay halfway.
  $ErrorActionPreference = "Continue"
  if (-not $s.worktree) { return }
  $wt = [string]$s.worktree
  $leftover = $false
  if (Test-Path -LiteralPath $wt) {
    # Anything the subthread didn't commit itself (its checks didn't pass, or it stopped) is still kept on its branch, marked as such.
    # A dropped build's unfinished work is discarded instead (the copy is removed with it); its own commits stay.
    if (-not $discard -and @(& git -C $wt status --porcelain 2>$null).Count) {
      & git -C $wt add -A 2>$null | Out-Null
      & git -C $wt commit -q -m "Smokey subthread (not committed by it; checks may not pass): $($s.title)" 2>$null | Out-Null
      $leftover = $true
    }
    Remove-Worktree ([string]$s.path) $wt
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
  if ($s.resume) { Resume-Sub $s; return }
  if (Test-Path -LiteralPath (Join-Path $where ".git")) {
    $branch = "$BranchPrefix/" + (Slug $s.title) + "-" + $s.id.Substring(3)
    # Inside the project (.claude\worktrees, as the Claude app does it), so its checks find the project's installed packages by walking up.
    $wt = Wt-Path $where "" ([string]$s.id)
    $base = (& git -C $where rev-parse HEAD 2>$null | Out-String).Trim()
    & git -C $where worktree add -q $wt -b $branch 2>$null | Out-Null
    if (-not (Test-Path -LiteralPath $wt)) { $s.state = "failed"; $s | Add-Member -Force result "Its own copy of $($s.folder) couldn't be made (git worktree), so it didn't start."; $s | Add-Member -Force finishedAt ((Get-Date).ToUniversalTime().ToString("o")); Save-Sub $s; Add-Note "Subthread `"$($s.title)`" ($($s.folder)) failed: $($s.result)"; return }
    Link-Packages $where $wt
    $s | Add-Member -Force worktree $wt; $s | Add-Member -Force branch $branch; $s | Add-Member -Force base $base
    $where = $wt
  }
  $prompt = @"
You are a subthread of the Smokey thread, running in the background with no one watching. Do this in the $($s.folder) project$(if ($s.branch) { " (your own copy of it, on the branch $($s.branch))" }):

$($s.task)

Work only in this folder.$(if ($s.branch) { @"

When the change is made, run the project's checks: its typecheck and unit tests (see the scripts in package.json, or pytest), and its linter if it has one. Fix what they catch and run them again until they pass. Then commit on your branch (git add, then git commit with a short message saying what changed). Commit only when the checks pass; if they can't pass, don't commit, and say what fails and why. You may run only those checks and git status, diff, log, show, add and commit: never push, merge, switch branches, deploy or delete anything.
"@ })
$(if ($s.build) { Ask-Rule $s })If something you need isn't allowed or isn't clear, don't guess: stop and say what's needed. Finish with a short plain summary (a few sentences) of what you did, what changed, which checks you ran and whether they passed, and whether you committed.
"@
  if ($s.build) { $prompt = "This is Smokey's own app: $($s.folder) is the app Smokey, $(Who $s)'s assistant, runs in, and this change is Smokey building something into himself that $(Who $s) agreed to. Read the project's CLAUDE.md first and follow it.`n`n" + $prompt }
  $p = Start-Claude $dir $where $(if ($s.branch) { @("--allowedTools") + $SubthreadTools } else { @() }) $prompt
  $s.state = "working"; $s | Add-Member -Force pid $p.Id; $s | Add-Member -Force startedAt ((Get-Date).ToUniversalTime().ToString("o")); Save-Sub $s
  Log "Subthread $($s.id) started in $where."
}

function Who($s) { if ($s.from) { return [string]$s.from } else { return "the person" } }
function Ask-Rule($s) {
  return @"
If you reach a decision you can't reasonably make yourself (something $(Who $s) would want a say in: wording, where it goes, which of two behaviours), don't guess and don't commit: stop, and end your final message with exactly these two lines:
QUESTION: <one short question for $(Who $s)>
OPTIONS: <first option> | <second option>
(two or three short options). Your work so far is kept, and you'll be picked up again with the answer. Ask only when it really matters; settle small things yourself, the way the code around it already does them.

"@
}

# A build that stopped on a question, picked up again with the answer: the same Claude Code session, in the same copy
# (made again from its branch if it was parked).
function Resume-Sub($s) {
  $ErrorActionPreference = "Continue"
  $dir = Join-Path $SubDir $s.id
  # The copy it was asking in, wherever it is (a build from before 4.3 has a tyrone- one); else a new one from its branch.
  $repo = [string]$s.path; $wt = if ($s.worktree -and (Test-Path -LiteralPath ([string]$s.worktree))) { [string]$s.worktree } else { Wt-Path $repo "" ([string]$s.id) }
  if (-not (Test-Path -LiteralPath $wt)) {
    & git -C $repo worktree add -q $wt ([string]$s.branch) 2>$null | Out-Null
    # Parked before it changed anything, its empty branch was dropped: start it again from where it began.
    if (-not (Test-Path -LiteralPath $wt)) { & git -C $repo worktree add -q $wt -b ([string]$s.branch) ([string]$s.base) 2>$null | Out-Null }
    if (-not (Test-Path -LiteralPath $wt)) { $s.state = "failed"; $s | Add-Member -Force result "Its copy couldn't be made again from $($s.branch), so it couldn't carry on."; $s | Add-Member -Force finishedAt ((Get-Date).ToUniversalTime().ToString("o")); $s.resume = $false; Save-Sub $s; return }
    Link-Packages $repo $wt
    $s | Add-Member -Force worktree $wt
  }
  # The last run's output stays for reference; the new run writes its own.
  foreach ($f in "out.json", "err.txt") { $old = Join-Path $dir $f; if (Test-Path -LiteralPath $old) { Move-Item -LiteralPath $old (Join-Path $dir ("before-" + (Get-Date -Format "HHmmss") + "-" + $f)) -Force } }
  $script:Streams.Remove($dir)
  $prompt = @"
$(Who $s) answered your question ("$($s.question)"): $($s.answer)

Carry on from where you stopped: finish the change, run the checks, and commit when they pass. If you must ask again, ask the same way (QUESTION and OPTIONS lines). Finish with a short plain summary as before.
"@
  $extra = @("--allowedTools") + $SubthreadTools
  if ($s.session) { $extra += @("--resume", [string]$s.session) } else { $prompt = "Task (you were working on this before): $($s.task)`n`n" + $prompt }
  $p = Start-Claude $dir $wt $extra $prompt
  $s.state = "working"; $s.resume = $false; $s | Add-Member -Force pid $p.Id; $s | Add-Member -Force startedAt ((Get-Date).ToUniversalTime().ToString("o"))
  foreach ($k in "question", "options", "askedAt") { $s.PSObject.Properties.Remove($k) }
  Save-Sub $s
  Log "Build $($s.id) carrying on with the answer."
}

# A finished build run's question, if it asked one: QUESTION and OPTIONS lines at the end.
function Read-Question([string]$text) {
  $q = [regex]::Match($text, '(?m)^\s*\**QUESTION:?\**\s*(.+?)\s*$')
  if (-not $q.Success) { return $null }
  $o = [regex]::Match($text, '(?m)^\s*\**OPTIONS:?\**\s*(.+?)\s*$')
  $opts = if ($o.Success) { @($o.Groups[1].Value -split '\s*\|\s*' | ForEach-Object { Clip $_ 200 } | Where-Object { $_ } | Select-Object -First 5) } else { @() }
  return @{ question = (Clip $q.Groups[1].Value 600); options = $opts }
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
    if ($r.session) { $s | Add-Member -Force session ([string]$r.session) }
    # A build that stopped on a question waits for the answer, its copy and session kept.
    $ask = if ($s.build -and $r.ok) { Read-Question ([string]$r.text) } else { $null }
    if ($ask) {
      $s.state = "asking"; $s | Add-Member -Force question $ask.question; $s | Add-Member -Force options @($ask.options); $s | Add-Member -Force askedAt ((Get-Date).ToUniversalTime().ToString("o"))
      Save-Sub $s; Log "Build $($s.id) is asking: $($ask.question)"; continue
    }
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
  # A question unanswered for a day: its copy is closed (its work kept on its branch); an answer still picks it up.
  foreach ($s in @(Get-Subthreads | Where-Object { $_.state -eq "asking" -and $_.askedAt -and ((Get-Date).ToUniversalTime() - [DateTime]::Parse([string]$_.askedAt).ToUniversalTime()).TotalHours -gt $AskHours })) {
    Close-Worktree $s; $s.state = "parked"; Save-Sub $s; Log "Build $($s.id) parked: no answer for $AskHours hours."
  }
  Check-Ships
  Check-Undos
  # Waiting ones start as places free up (one waiting on an answer holds its place); a project with no git gets one subthread at a time.
  $working = @(Get-Subthreads | Where-Object { $_.state -eq "working" -or $_.state -eq "asking" })
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
  $wt = Wt-Path $repo "live" $sid
  try {
    Ship-Step $sid "going" "Getting the latest $($s.folder) from GitHub"
    & git -C $repo fetch -q origin 2>$null | Out-Null
    if ($LASTEXITCODE) { throw "Couldn't reach GitHub (git fetch failed), so it isn't live. It's still on $branch." }
    Remove-Worktree $repo $wt
    & git -C $repo worktree add -q --detach $wt origin/main 2>$null | Out-Null
    if (-not (Test-Path -LiteralPath $wt)) { throw "Couldn't make a copy of main to merge into, so it isn't live. It's still on $branch." }
    Link-Packages $repo $wt
    Ship-Step $sid "going" "Merging $branch into main"
    foreach ($from in @($branch, "origin/$($g.branch)")) {
      $null = (& git -C $wt merge --no-edit -m "Merge $from (Smokey: $($s.title))" $from 2>&1 | Out-String)
      if ($LASTEXITCODE) {
        $files = @(& git -C $wt diff --name-only --diff-filter=U 2>$null) -join ", "
        & git -C $wt merge --abort 2>$null | Out-Null
        throw "It clashes with newer changes on $(if ($from -eq $branch) { 'main' } else { $g.branch })$(if ($files) { " in $files" }), so it wasn't merged or pushed. It's still on $branch."
      }
    }
    foreach ($c in @($g.checks | Where-Object { $_ })) {
      Ship-Step $sid "going" "Running $c on the merged code"
      Push-Location -LiteralPath $wt
      $savedPath = $env:PATH; $savedVenv = $env:VIRTUAL_ENV; $savedNoColor = $env:NO_COLOR; $savedForce = $env:FORCE_COLOR
      # Plain output (no colour codes), so a failure reads cleanly in the chat.
      try { Use-ProjectTools $wt; $env:NO_COLOR = "1"; $env:FORCE_COLOR = "0"; $out = Run-Check $c; $code = $LASTEXITCODE } finally { $env:PATH = $savedPath; $env:VIRTUAL_ENV = $savedVenv; $env:NO_COLOR = $savedNoColor; $env:FORCE_COLOR = $savedForce; Pop-Location }
      if ($code) { throw "$c failed on the merged code, so nothing was pushed. It's still on $branch. What it said: $(Check-Failure $out)" }
    }
    $commit = (& git -C $wt rev-parse HEAD 2>$null | Out-String).Trim()
    $h8 = $commit.Substring(0, 8)
    Ship-Step $sid "going" "Pushing $h8 to main and $($g.branch)" $commit
    $refs = @("HEAD:refs/heads/main") + $(if ($g.branch -and $g.branch -ne "main") { @("HEAD:refs/heads/$($g.branch)") } else { @() })
    $out = (& git -C $wt push -q origin @refs 2>&1 | Out-String)
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
    Remove-Worktree $repo $wt
  }
}

# ---- Undo (4.0): a live build taken back out. Its own changes (its branch since it started) are reversed on the latest
# main, checked, pushed and deployed like going live. Run by the relay, hidden: -Undo <id>.
function Undo-Step([string]$sid, [string]$state, [string]$text, [string]$commit = "") {
  $file = Ship-File $sid "undo.json"
  $u = Read-Json $file; if (-not $u) { $u = [pscustomobject]@{ state = $state; steps = @() } }
  $u.state = $state
  if ($text) { $u.steps = @(@($u.steps) + @([pscustomobject]@{ at = (Get-Date).ToUniversalTime().ToString("o"); text = (Clip $text 200) }) | Select-Object -Last 10); $u | Add-Member -Force detail (Clip $text 1500) }
  if ($commit) { $u | Add-Member -Force commit $commit }
  Write-Json $file $u
  Log "Undo, ${sid}: $(Clip $text 300)"
}

function Run-Undo([string]$sid) {
  $ErrorActionPreference = "Continue"
  $s = Read-Json (Ship-File $sid "sub.json")
  if (-not $s) { return }
  $g = $GoLive[([string]$s.folder).ToLower()]
  if (-not $g) { Undo-Step $sid "failed" "$($s.folder) has no go-live steps."; return }
  $repo = [string]$s.path; $branch = [string]$s.branch
  $wt = Wt-Path $repo "undo" $sid
  $patch = Ship-File $sid "undo.patch"
  try {
    Undo-Step $sid "going" "Getting the latest $($s.folder) from GitHub"
    & git -C $repo fetch -q origin 2>$null | Out-Null
    if ($LASTEXITCODE) { throw "Couldn't reach GitHub (git fetch failed), so nothing was undone." }
    Remove-Worktree $repo $wt
    & git -C $repo worktree add -q --detach $wt origin/main 2>$null | Out-Null
    if (-not (Test-Path -LiteralPath $wt)) { throw "Couldn't make a copy of main, so nothing was undone." }
    Link-Packages $repo $wt
    Undo-Step $sid "going" "Reversing its changes on main"
    & cmd.exe /c "git -C `"$repo`" diff --binary $($s.base) $branch > `"$patch`"" 2>$null
    if (-not (Test-Path -LiteralPath $patch) -or (Get-Item -LiteralPath $patch).Length -eq 0) { throw "Its changes couldn't be found on $branch, so nothing was undone." }
    $out = (& git -C $wt apply -R --3way $patch 2>&1 | Out-String)
    if ($LASTEXITCODE -or @(& git -C $wt diff --name-only --diff-filter=U 2>$null).Count) { throw "Newer changes on main touch the same lines, so it can't be taken out cleanly; nothing was pushed. $(Clip $out 300)" }
    & git -C $wt add -A 2>$null | Out-Null
    & git -C $wt commit -q -m "Undo: $($s.title) (Smokey)" 2>$null | Out-Null
    if ($LASTEXITCODE) { throw "There was nothing left to take out (main no longer has its changes)." }
    $null = (& git -C $wt merge --no-edit -m "Merge origin/$($g.branch) (Smokey undo)" "origin/$($g.branch)" 2>&1 | Out-String)
    if ($LASTEXITCODE) { & git -C $wt merge --abort 2>$null | Out-Null; throw "It clashes with newer changes on $($g.branch), so nothing was pushed." }
    Push-Live $sid $wt $g { param($st, $tx, $c) Undo-Step $sid $(if ($st -eq "live") { "done" } else { $st }) $tx $c } "Undone"
  } catch {
    Undo-Step $sid "failed" ([string]$_.Exception.Message)
  } finally {
    Remove-Worktree $repo $wt
    Remove-Item -LiteralPath $patch -Force -ErrorAction SilentlyContinue
  }
}

# The checks on the result, then push to main (and the deploy branch), deploy and wait for it to be live. $step is
# called with (state, text, commit): "going" as it goes, "live" at the end; it throws when something fails.
function Push-Live([string]$sid, [string]$wt, $g, [scriptblock]$step, [string]$doneWord = "Live") {
  foreach ($c in @($g.checks | Where-Object { $_ })) {
    & $step "going" "Running $c on the result" ""
    Push-Location -LiteralPath $wt
    $savedPath = $env:PATH; $savedVenv = $env:VIRTUAL_ENV; $savedNoColor = $env:NO_COLOR; $savedForce = $env:FORCE_COLOR
    try { Use-ProjectTools $wt; $env:NO_COLOR = "1"; $env:FORCE_COLOR = "0"; $out = Run-Check $c; $code = $LASTEXITCODE } finally { $env:PATH = $savedPath; $env:VIRTUAL_ENV = $savedVenv; $env:NO_COLOR = $savedNoColor; $env:FORCE_COLOR = $savedForce; Pop-Location }
    if ($code) { throw "$c failed, so nothing was pushed. What it said: $(Check-Failure $out)" }
  }
  $commit = (& git -C $wt rev-parse HEAD 2>$null | Out-String).Trim()
  $h8 = $commit.Substring(0, 8)
  & $step "going" "Pushing $h8 to main and $($g.branch)" $commit
  $refs = @("HEAD:refs/heads/main") + $(if ($g.branch -and $g.branch -ne "main") { @("HEAD:refs/heads/$($g.branch)") } else { @() })
  $out = (& git -C $wt push -q origin @refs 2>&1 | Out-String)
  if ($LASTEXITCODE) { throw "GitHub refused the push (someone may have pushed at the same moment), so nothing changed. $(Clip $out 300)" }
  if (-not $g.host) { & $step "live" "$doneWord`: pushed $h8 to main and $($g.branch)." $commit; return }
  & $step "going" "Deploying $h8 to $($g.branch)" $commit
  $out = (& ssh -o BatchMode=yes -o ConnectTimeout=15 $g.host $g.deploy 2>&1 | Out-String)
  if ($LASTEXITCODE) { throw "It's pushed to main and $($g.branch) ($h8), but the deploy couldn't start: $(Clip $out 300)" }
  $until = (Get-Date).AddMinutes($GoLiveMinutes)
  while ((Get-Date) -lt $until) {
    $st = (& ssh -o BatchMode=yes -o ConnectTimeout=15 $g.host $g.status 2>&1 | Out-String)
    if (@($st -split "`n" | Where-Object { $_ -match "^\s*$([regex]::Escape($g.app))\s" -and $_ -match "$h8 live" }).Count) { & $step "live" "$doneWord on $($g.branch): $h8." $commit; return }
    Start-Sleep -Seconds 20
  }
  throw "Pushed $h8 to main and $($g.branch) and started the deploy, but it didn't show as live within $GoLiveMinutes minutes. Check ltg-dev-deploy status."
}

# An undo whose hidden process died (the PC restarted) is marked failed, so it can be asked for again.
function Check-Undos {
  foreach ($s in @(Get-Subthreads | Where-Object { $_.build })) {
    $u = Read-Json (Ship-File $s.id "undo.json")
    if (-not $u -or $u.state -ne "going") { continue }
    $pidFile = Ship-File $s.id "undo.pid"
    $p = if (Test-Path -LiteralPath $pidFile) { Get-Process -Id ([int](Get-Content -LiteralPath $pidFile -Raw)) -ErrorAction SilentlyContinue } else { $null }
    if (-not ($p -and -not $p.HasExited -and $p.ProcessName -match "powershell")) { Undo-Step $s.id "failed" "The undo stopped partway (the PC may have restarted). Ask again to take it out." }
  }
}

# Starts waiting ones (one per project at a time), notices one that died, and tells the Smokey thread how each ended.
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

# ---- Merged by hand (4.1): what actually happened to each smokey/ (or older tyrone/) branch after the relay was done with it ----
# A branch that didn't go live on its own (a clash, a failed check, a project with no go-live steps) is often merged
# by someone later, sometimes as a copy brought up to main. Every two minutes the relay looks at git and the devbox:
# each smokey/ (or older tyrone/) branch is "merged" (its last commit is in main's history), "copied" (main has the same changes, or a
# commit on main names its last commit), or not on main yet; one that's on main is checked against the deploy
# branch and what's live. Each subthread's merged.json is updated, and the whole list goes to the app with the live
# report, so Smokey's job list says what really happened.
$BranchesFile = Join-Path $Folder "branches.json"
$script:BranchList = @()

function Git-Lines([string]$repo, [string[]]$a) { $ErrorActionPreference = "Continue"; return @(& git -C $repo @a 2>$null | Where-Object { $_ }) }
function Git-One([string]$repo, [string[]]$a) { $l = @(Git-Lines $repo $a); if ($l.Count) { return [string]$l[0] }; return "" }
function Git-Ok([string]$repo, [string[]]$a) { $ErrorActionPreference = "Continue"; & git -C $repo @a 2>$null | Out-Null; return $LASTEXITCODE -eq 0 }

# Where a branch's work is on main: @{ how = "merged" | "copied"; commit = the first main commit that has it }, or $null.
function Find-OnMain([string]$repo, [string]$branch, [string]$head, [string]$base) {
  if (Git-Ok $repo @("merge-base", "--is-ancestor", $head, "origin/main")) {
    $first = @(Git-Lines $repo @("rev-list", "--ancestry-path", "--reverse", "$head..origin/main") | Select-Object -First 1)
    return @{ how = "merged"; commit = $(if ($first.Count) { [string]$first[0] } else { $head }) }
  }
  $since = @(Git-Lines $repo @("log", "-1", "--format=%cI", $head))
  # A copy brought up to main says where it came from ("... from 3c991fc", "Merge smokey/..."): the oldest such commit.
  foreach ($needle in @($head.Substring(0, 7), $branch)) {
    $a = @("log", "origin/main", "--fixed-strings", "--grep=$needle", "--format=%H"); if ($since.Count) { $a += "--since=$($since[0])" }
    $hit = @(Git-Lines $repo $a | Select-Object -Last 1)
    if ($hit.Count) { return @{ how = "copied"; commit = [string]$hit[0] } }
  }
  # A copy redone by hand on main that kept the branch's commit message word for word (4.2).
  $subject = Git-One $repo @("log", "-1", "--format=%s", $head)
  if ($subject.Length -ge 20) {
    # Compared here, not with git's --grep: Windows PowerShell mangles double quotes in a native command's arguments.
    $a = @("log", "origin/main", "--format=%H`t%s"); if ($since.Count) { $a += "--since=$($since[0])" } else { $a += "-500" }
    $hit = @(Git-Lines $repo $a | Where-Object { ($_ -split "`t", 2)[1] -eq $subject } | Select-Object -Last 1)
    if ($hit.Count) { return @{ how = "copied"; commit = (([string]$hit[0]) -split "`t")[0] } }
  }
  # The same changes, commit for commit (cherry-picked or rebased onto main).
  if ($base) {
    $ch = @(Git-Lines $repo @("cherry", "origin/main", $head, $base))
    if ($ch.Count -and -not @($ch | Where-Object { $_ -like "+*" }).Count) { return @{ how = "copied"; commit = (Git-One $repo @("rev-parse", "origin/main")) } }
  }
  return $null
}

# The commit live on the devbox for a go-live recipe (its full hash), or "" when it can't be read.
function Live-Commit([string]$repo, $g) {
  if (-not $g.host -or -not $g.status) { return "" }
  $ErrorActionPreference = "Continue"
  $st = (& ssh -o BatchMode=yes -o ConnectTimeout=15 $g.host $g.status 2>&1 | Out-String)
  $m = [regex]::Match($st, "(?m)^\s*$([regex]::Escape($g.app))\s.*?\b([0-9a-f]{8}) live\b")
  if (-not $m.Success) { return "" }
  return (Git-One $repo @("rev-parse", "--verify", "-q", "$($m.Groups[1].Value)^{commit}"))
}

function Check-Merged {
  $ErrorActionPreference = "Continue"
  $subs = @(Get-Subthreads)
  # Every repo a subthread worked in, and each project with go-live steps.
  $repos = @{}
  foreach ($s in $subs) { if ($s.path -and (Test-Path -LiteralPath (Join-Path ([string]$s.path) ".git"))) { $repos[([string]$s.path).ToLower()] = @{ path = [string]$s.path; name = [string]$s.folder } } }
  $known = Get-JobFolders
  foreach ($k in $GoLive.Keys) { $f = $known[$k]; if ($f -and (Test-Path -LiteralPath (Join-Path $f.path ".git"))) { $repos[$f.path.ToLower()] = @{ path = $f.path; name = $f.name } } }
  $cache = @{}; $old = Read-Json $BranchesFile
  if ($old) { foreach ($b in @($old.branches)) { $cache["$($b.folder)|$($b.branch)"] = $b } }
  $out = @()
  foreach ($r in $repos.Values) {
    $repo = $r.path
    $refs = @(Git-Lines $repo (@("for-each-ref", "--format=%(refname:short)`t%(objectname)`t%(committerdate:iso-strict)") + @($BranchPrefixes | ForEach-Object { "refs/heads/$_/" })))
    if (-not $refs.Count) { continue }
    $null = Git-Ok $repo @("fetch", "-q", "origin")
    $mainTip = Git-One $repo @("rev-parse", "origin/main")
    $g = $GoLive[([string]$r.name).ToLower()]
    $devTip = if ($g -and $g.branch -and $g.branch -ne "main") { Git-One $repo @("rev-parse", "origin/$($g.branch)") } else { $mainTip }
    $live = $null
    foreach ($line in $refs) {
      $p = $line -split "`t"; $branch = $p[0]; $head = $p[1]
      $sub = $subs | Where-Object { $_.branch -eq $branch } | Select-Object -First 1
      $c = $cache["$($r.name)|$branch"]
      # Settled ones aren't looked at again (until a new relay version, which may judge them differently); others when the branch or main moved, or (on main) when dev or what's live may have.
      if ($c -and [string]$c.v -eq $Version -and $c.head -eq $head -and ($c.live -or ($c.mainTip -eq $mainTip -and -not $c.onMain))) { $out += $c; continue }
      $hit = Find-OnMain $repo $branch $head $(if ($sub) { [string]$sub.base } else { "" })
      $b = [ordered]@{ v = $Version; folder = $r.name; branch = $branch; head = $head; at = $p[2]; mainTip = $mainTip; onMain = [bool]$hit; checkedAt = (Get-Date).ToUniversalTime().ToString("o") }
      if ($hit) {
        $b.how = $hit.how; $b.commit = $hit.commit
        $b.onDev = Git-Ok $repo @("merge-base", "--is-ancestor", $hit.commit, $devTip)
        if ($b.onDev) {
          if (-not $g -or -not $g.host) {
            # Deploys itself when pushed (officepet), or no deploy steps known: on the branch is as far as the relay can see.
            if ($g) { $b.live = $true; $b.deploy = $hit.commit }
          } else {
            if ($null -eq $live) { $live = Live-Commit $repo $g }
            if ($live -and (Git-Ok $repo @("merge-base", "--is-ancestor", $hit.commit, $live))) { $b.live = $true; $b.deploy = $live }
          }
        }
      }
      if (-not $b.live) { $b.live = $false }
      $out += [pscustomobject]$b
    }
  }
  $script:BranchList = @($out | Sort-Object { [string]$_.at } -Descending)
  Write-Json $BranchesFile ([pscustomobject]@{ at = (Get-Date).ToUniversalTime().ToString("o"); branches = $script:BranchList })
  # Each subthread that didn't go live on its own hears where its branch ended up.
  foreach ($s in $subs) {
    if (-not $s.branch -or -not $s.kept) { continue }
    $sh = Read-Json (Ship-File $s.id "ship.json")
    if ($sh -and @("waiting", "going", "live") -contains [string]$sh.state) { continue }
    $b = $script:BranchList | Where-Object { $_.branch -eq $s.branch -and $_.onMain } | Select-Object -First 1
    if (-not $b) {
      # A job that couldn't go live whose branch was then deleted, here and on GitHub, without reaching main (4.2):
      # it was dropped, usually for a later job or a hand-made copy, so it's no longer "still on the branch".
      $repo = [string]$s.path
      if (-not $sh -or [string]$sh.state -ne "failed" -or -not $repo -or -not (Test-Path -LiteralPath (Join-Path $repo ".git"))) { continue }
      if (Git-Ok $repo @("rev-parse", "--verify", "-q", "refs/heads/$($s.branch)")) { continue }
      if (Git-Ok $repo @("rev-parse", "--verify", "-q", "refs/remotes/origin/$($s.branch)")) { continue }
      $file = Ship-File $s.id "merged.json"
      $was = Read-Json $file
      if ($was) { continue }
      Write-Json $file ([pscustomobject][ordered]@{ state = "dropped"; how = "deleted"; commit = ""; at = (Get-Date).ToUniversalTime().ToString("o") })
      Add-Note "Subthread $($s.id) `"$($s.title)`" ($($s.folder)) was dropped: its branch $($s.branch) was deleted without being merged."
      Log "Subthread $($s.id) dropped: $($s.branch) deleted without reaching main."
      continue
    }
    $m = [ordered]@{ state = $(if ($b.live) { "live" } else { "merged" }); how = [string]$b.how; commit = [string]$b.commit }
    if ($b.onDev) { $m.onDev = $true }
    if ($b.deploy) { $m.deploy = [string]$b.deploy }
    $file = Ship-File $s.id "merged.json"
    $was = Read-Json $file
    if ($was -and $was.state -eq $m.state -and [string]$was.commit -eq $m.commit -and [string]$was.deploy -eq [string]$m.deploy) { continue }
    $m.at = (Get-Date).ToUniversalTime().ToString("o")
    Write-Json $file ([pscustomobject]$m)
    Add-Note "Subthread $($s.id) `"$($s.title)`" ($($s.folder)) was $(if ($m.how -eq 'copied') { 'copied' } else { 'merged' }) into main by hand ($($m.commit.Substring(0, 8)))$(if ($m.state -eq 'live') { " and is live$(if ($m.deploy) { " ($($m.deploy.Substring(0, 8)))" })" })."
    Log "Subthread $($s.id) $($m.state) by hand: $($m.how) in $($m.commit.Substring(0, 8))$(if ($m.deploy) { ", live $($m.deploy.Substring(0, 8))" })."
  }
}

# ---- Live: what the Smokey thread and its subthreads are doing, step by step, for Talk ----
function Live-Body {
  $job = $null
  foreach ($d in @(Get-ChildItem $JobsDir -Directory -ErrorAction SilentlyContinue)) {
    if (Test-Path (Join-Path $d.FullName "done.txt")) { continue }
    $j = Read-Json (Join-Path $d.FullName "job.json")
    if ($j -and (Is-Running $j)) { $st = Read-Stream $d.FullName; $job = @{ id = $d.Name; task = (Clip ([string]$j.task) 300); startedAt = ([DateTime]::Parse([string]$j.started)).ToUniversalTime().ToString("o"); steps = @($st.steps | Select-Object -Last 10) } }
  }
  $day = (Get-Date).ToUniversalTime().AddHours(-24)
  # Grouped explicitly: in PowerShell -and and -or bind equally, left to right, so without the brackets a finished
  # subthread whose going live was noted (ship.told) was left out, and the app never heard it went live (4.0.1).
  $subs = @(Get-Subthreads | Where-Object {
    if ($_.state -eq "dropped") { return $false }
    $active = @("queued", "working", "asking", "parked") -contains [string]$_.state
    $recent = [bool]($_.finishedAt -and [DateTime]::Parse([string]$_.finishedAt).ToUniversalTime() -gt $day)
    $shipping = (Test-Path -LiteralPath (Ship-File $_.id "ship.pid")) -and -not (Test-Path -LiteralPath (Ship-File $_.id "ship.told"))
    $undoing = (Test-Path -LiteralPath (Ship-File $_.id "undo.json")) -and ((Get-Item -LiteralPath (Ship-File $_.id "undo.json")).LastWriteTimeUtc -gt $day)
    $mergedLately = (Test-Path -LiteralPath (Ship-File $_.id "merged.json")) -and ((Get-Item -LiteralPath (Ship-File $_.id "merged.json")).LastWriteTimeUtc -gt $day)
    $active -or $recent -or $shipping -or $undoing -or $mergedLately
  } | ForEach-Object {
    $st = if ($_.state -eq "working") { Read-Stream (Join-Path $SubDir $_.id) } else { $null }
    $o = [ordered]@{ id = $_.id; title = $_.title; folder = $_.folder; state = $_.state }
    foreach ($k in "queuedAt", "startedAt", "finishedAt", "branch", "result", "list", "item", "question") { if ($_.$k) { $o[$k] = [string]$_.$k } }
    if ($_.options) { $o.options = @($_.options | ForEach-Object { [string]$_ }) }
    $u = Read-Json (Ship-File $_.id "undo.json")
    if ($u) { $o.undo = [ordered]@{ state = [string]$u.state; detail = [string]$u.detail }; if ($u.commit) { $o.undo.commit = [string]$u.commit } }
    if ($st) { $o.steps = @($st.steps | Select-Object -Last 6) }
    $g = Read-Json (Ship-File $_.id "ship.json")
    if ($g) { $o.ship = [ordered]@{ state = [string]$g.state; detail = [string]$g.detail; steps = @($g.steps | Select-Object -Last 6) }; if ($g.commit) { $o.ship.commit = [string]$g.commit } }
    $m = Read-Json (Ship-File $_.id "merged.json")
    if ($m) { $o.merged = [ordered]@{ state = [string]$m.state; how = [string]$m.how; commit = [string]$m.commit; at = [string]$m.at }; if ($m.onDev) { $o.merged.onDev = $true }; if ($m.deploy) { $o.merged.deploy = [string]$m.deploy } }
    $o
  })
  # Every smokey/ and tyrone/ branch and whether it's on main, dev and live (newest first), as of the last check.
  $branches = @($script:BranchList | Select-Object -First 60 | ForEach-Object {
    $b = [ordered]@{ folder = [string]$_.folder; branch = [string]$_.branch; head = [string]$_.head; at = [string]$_.at; onMain = [bool]$_.onMain; checkedAt = [string]$_.checkedAt }
    if ($_.onMain) { $b.how = [string]$_.how; $b.commit = [string]$_.commit; $b.onDev = [bool]$_.onDev; $b.live = [bool]$_.live; if ($_.deploy) { $b.deploy = [string]$_.deploy } }
    $b
  })
  # Sent as "smokey" and, until the app reads that, as "tyrone" too (the key the app read before the rename): the same report.
  $report = @{ version = $Version; state = $(if ($job) { "working" } else { "idle" }); job = $job; subthreads = $subs; max = $MaxSubthreads; branches = $branches }
  return @{ smokey = $report; tyrone = $report }
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

function Busy { return [bool]((@(Get-ChildItem $JobsDir -Directory -ErrorAction SilentlyContinue | Where-Object { -not (Test-Path (Join-Path $_.FullName "done.txt")) -and (Test-Path (Join-Path $_.FullName "job.json")) }).Count) -or @(Get-Subthreads | Where-Object { $_.state -eq "working" -or $_.state -eq "queued" -or @("waiting", "going") -contains [string](Read-Json (Ship-File $_.id "ship.json")).state -or [string](Read-Json (Ship-File $_.id "undo.json")).state -eq "going" }).Count) }

# ---- Smokey building himself (4.0): an item from his features and bugs list, straight to a subthread ----
function Find-Sub([string]$sid, [string]$item) {
  $all = @(Get-Subthreads)
  $hit = if ($sid) { $all | Where-Object { $_.id -eq $sid } | Select-Object -First 1 } else { $null }
  if (-not $hit -and $item) { $hit = $all | Where-Object { [string]$_.item -eq $item } | Sort-Object { [string]$_.queuedAt } -Descending | Select-Object -First 1 }
  return $hit
}

# Drops a build that hasn't finished: its Claude Code run stops, its copy goes (unfinished work discarded), a branch
# with commits of its own is kept and an empty one deleted, and it's marked dropped: not counted, not reported to the
# app (which already cleared it), and not tried again.
function Drop-Sub($s) {
  $ErrorActionPreference = "Continue"
  if ($s.pid) { Stop-Process -Id ([int]$s.pid) -Force -ErrorAction SilentlyContinue }
  $s.state = "dropped"
  $s | Add-Member -Force finishedAt ((Get-Date).ToUniversalTime().ToString("o"))
  $s | Add-Member -Force result "Dropped by its owner."
  Save-Sub $s
  if ($s.branch) { Close-Worktree $s $true }
  Log "Build $($s.id) dropped$(if ($s.kept) { ": its $($s.commits) commit(s) stay on $($s.branch)" } elseif ($s.branch) { ': its empty branch was deleted' } else { '' })."
}

function Take-Build($key, $t) {
  $b = $t.claude.build; $id = [string]$t.id
  $dir = Join-Path $JobsDir $id
  if (Test-Path $dir) { return }
  $null = New-Item -ItemType Directory -Force $dir
  $finish = { param($ok, $text) Report $key $id $(if ($ok) { "done" } else { "failed" }) $text | Out-Null; Set-Content (Join-Path $dir "done.txt") $(if ($ok) { "done" } else { "failed" }) }
  switch ([string]$b.kind) {
    "build" {
      $problem = Claude-Problem
      $match = (Get-JobFolders)[$BuildFolder]
      if (-not $problem -and -not $match) { $problem = "$BuildFolder isn't a project on this PC (no Claude Code thread ran there in the last 30 days)." }
      if ($problem) { & $finish $false $problem; Log "Build $id not started: $problem"; return }
      $sid = "st-" + ([guid]::NewGuid().ToString("N").Substring(0, 6))
      $null = New-Item -ItemType Directory -Force (Join-Path $SubDir $sid)
      $title = Clip $(if ($b.title) { [string]$b.title } else { [string]$t.task }) 80
      Save-Sub ([pscustomobject]@{ id = $sid; title = $title; folder = $match.name; path = $match.path; task = [string]$t.task; state = "queued"; queuedAt = (Get-Date).ToUniversalTime().ToString("o"); list = [string]$b.listId; item = [string]$b.itemId; from = [string]$t.from; build = $true })
      & $finish $true "Building it in subthread $sid."
      Log "Build $sid queued: $title."
    }
    "answer" {
      $s = Find-Sub ([string]$b.sub) ([string]$b.itemId)
      if (-not $s -or @("asking", "parked") -notcontains [string]$s.state) { & $finish $false "That build isn't waiting on an answer any more."; return }
      $s.state = "queued"; $s | Add-Member -Force answer ([string]$b.answer); $s | Add-Member -Force resume $true; $s | Add-Member -Force queuedAt ((Get-Date).ToUniversalTime().ToString("o")); Save-Sub $s
      & $finish $true "Passed on; it carries on."
      Log "Build $($s.id) answered."
    }
    "undo" {
      $s = Find-Sub ([string]$b.sub) ([string]$b.itemId)
      $g = if ($s) { Read-Json (Ship-File $s.id "ship.json") } else { $null }
      $hand = if ($s) { Read-Json (Ship-File $s.id "merged.json") } else { $null }
      if (-not $s -or -not (($g -and $g.state -eq "live") -or ($hand -and $hand.state -eq "live"))) { & $finish $false "That build isn't live, so there's nothing to undo."; return }
      $u = Read-Json (Ship-File $s.id "undo.json")
      if ($u -and $u.state -eq "going") { & $finish $true "Already being undone."; return }
      Write-Json (Ship-File $s.id "undo.json") ([pscustomobject]@{ state = "going"; steps = @(); detail = "Starting" })
      $p = Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Undo $($s.id)" -WindowStyle Hidden -PassThru
      Set-Content -LiteralPath (Ship-File $s.id "undo.pid") -Value $p.Id
      & $finish $true "Taking it back out."
      Log "Build $($s.id) being undone."
    }
    "drop" {
      # Dropped by its owner (4.4): stopped and closed, its place freed, never reported again or tried again.
      $s = Find-Sub ([string]$b.sub) ([string]$b.itemId)
      if (-not $s -or @("queued", "working", "asking", "parked") -notcontains [string]$s.state) { & $finish $true "Nothing to drop: no unfinished build of it on this PC."; Log "Drop $id`: nothing unfinished to drop."; return }
      Drop-Sub $s
      & $finish $true "Dropped$(if ($s.kept) { "; its $($s.commits) commit(s) stay on $($s.branch)" } else { '' })."
    }
    default { & $finish $false "Unknown build step." }
  }
}

function Poll-Jobs([string]$key) {
  $null = New-Item -ItemType Directory -Force $JobsDir, $SubDir, $WtDir, $SpawnDir
  $tasks = @(((Web $key).DownloadString($TasksUrl) | ConvertFrom-Json).tasks)
  $open = @($tasks | ForEach-Object { [string]$_.id })
  # Builds go straight to a subthread, not the Smokey thread.
  foreach ($t in @($tasks | Where-Object { $_.claude -and $_.claude.build })) { Take-Build $key $t }
  Check-Jobs $key $open
  # One Smokey job at a time: the next one starts when it's free.
  $running = @(Get-ChildItem $JobsDir -Directory -ErrorAction SilentlyContinue | Where-Object { (Test-Path (Join-Path $_.FullName "job.json")) -and -not (Test-Path (Join-Path $_.FullName "done.txt")) }).Count
  if (-not $running) {
    $next = $tasks | Where-Object { $_.claude -and -not $_.claude.build -and -not (Test-Path (Join-Path $JobsDir ([string]$_.id))) } | Select-Object -First 1
    if ($next) { Start-SmokeyJob $key $next }
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
      $html = if ($ok) { "<!doctype html><meta charset=utf-8><title>Connected</title><body style='font-family:Segoe UI,sans-serif;padding:40px'><h1>Connected</h1><p>The Claude relay on this PC can now tell Smokey about your Claude Code threads. You can close this window.</p>" } else { "<!doctype html><meta charset=utf-8><title>Not connected</title><body style='font-family:Segoe UI,sans-serif;padding:40px'><h1>Not connected</h1><p>That didn't come from this connect. Run ClaudeRelay.ps1 -Connect again.</p>" }
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
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Tells Smokey (Project Check-in) what's going on in your Claude Code threads. $self" -Force | Out-Null
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
  Write-Host ("The Smokey thread works in: $SmokeyHome (outside your projects: every change goes to a subthread, on its own branch)")
  $ty = Get-Smokey
  Write-Host ("Smokey thread session: " + $(if ($ty.sessionId) { $ty.sessionId } else { "not started yet (the first job starts it)" }))
  Write-Host "Projects it and its subthreads can work on (where a Claude Code thread ran in the last 30 days):"
  (Get-JobFolders).Values | Sort-Object { $_.name } | ForEach-Object { Write-Host ("  " + $_.name + "  " + $_.path) }
  exit 0
}

if ($DryRun) { ConvertTo-Json -InputObject @{ threads = @(Get-Threads); folders = @((Get-JobFolders).Values | ForEach-Object { $_.name } | Sort-Object) } -Depth 4; exit 0 }

# -Branches: checks every smokey/ and tyrone/ branch now and shows where each is (on main, on dev, live), sends nothing.
if ($Branches) { Check-Merged; ConvertTo-Json -InputObject @($script:BranchList) -Depth 4; exit 0 }
# -Ship <subthread id>: the relay starts this, hidden, to put one finished subthread live.
if ($Ship) { Run-Ship $Ship; exit 0 }
# -Undo <subthread id>: the relay starts this, hidden, to take a live build back out.
if ($Undo) { Run-Undo $Undo; exit 0 }

$key = Get-Key
if (-not $key) { Write-Host "Not connected yet: run ClaudeRelay.ps1 -Connect" -ForegroundColor Yellow; exit 1 }
if ($Once) { try { Log (Send-Threads $key); exit 0 } catch { Log ("Not sent: " + (Why $_)); exit 1 } }

# One relay at a time.
$mutex = New-Object System.Threading.Mutex($false, "Local\ClaudeRelay")
if (-not $mutex.WaitOne(0)) { Write-Host "The Claude relay is already running." -ForegroundColor Yellow; exit 0 }
Log "Claude relay $Version running: sending your threads every two minutes, jobs to the Smokey thread (up to $MaxSubthreads subthreads), live steps while anything runs."
$lastNote = ""; $lastJobNote = ""; $lastLiveNote = ""; $nextThreads = Get-Date; $nextJobs = Get-Date
while ($true) {
  $key = Get-Key
  if ((Get-Date) -ge $nextThreads) {
    $note = if (-not $key) { "Not connected: run ClaudeRelay.ps1 -Connect" } else { try { Send-Threads $key } catch { "Not sent: " + (Why $_) } }
    # The log gets a line when something changes, not every two minutes.
    if ($note -ne $lastNote) { Log $note; $lastNote = $note }
    # Where each smokey/ (or older tyrone/) branch ended up (merged or copied into main by hand, deployed), for Smokey's job list.
    try { Check-Merged } catch { Log ("Branches not checked: " + (Why $_)) }
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
