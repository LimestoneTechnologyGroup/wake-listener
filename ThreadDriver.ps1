# Thread driver: Tyrone types into your real Claude Code threads.
#
# Run it on the PC where the Claude desktop app runs your threads, next to the
# Claude relay (it uses the relay's key). When you tell Tyrone "tell the
# project-checkin thread to run the tests again", this opens that thread in
# the Claude app, pastes the message into its box and presses Enter, exactly
# as if you'd typed it. The thread works with its own settings and shows in the
# app and on your phone (Remote Control). When the thread finishes its turn,
# its answer goes back to Tyrone and your chat.
#
# What it won't do: type into a thread that's busy (it waits), type while the
# PC is locked (it waits), overwrite something you've half-typed in that
# thread's box (it waits), or click anything else. It never answers a
# permission prompt: when a thread stops to ask, Tyrone tells you, and you
# approve it yourself, on the PC or your phone.
#
#   ThreadDriver.ps1 -Doctor                 checks it can see the Claude app and the relay's key
#   ThreadDriver.ps1 -Type <thread id> "msg" types one message into a thread now (a test), and waits for the answer
#   ThreadDriver.ps1 -List                   sends Tyrone the list of your threads once
#   ThreadDriver.ps1 -Install                starts it hidden at every sign-in (a scheduled task), and now
#   ThreadDriver.ps1 -Uninstall              stops it and removes the scheduled task
#   ThreadDriver.ps1                         runs in this window, checking every 10 seconds
param([switch]$Doctor, [switch]$List, [string]$Type, [string]$Message, [switch]$Install, [switch]$Uninstall, [string]$Base = "https://project-checkin.dev.limestonetg.com")

$ErrorActionPreference = "Stop"
$Version = "1.2.0"
$Folder = Join-Path $env:LOCALAPPDATA "ThreadDriver"
$RelayKey = Join-Path $env:LOCALAPPDATA "ClaudeRelay\key.txt"
$LogFile = Join-Path $Folder "driver.log"
$StateFile = Join-Path $Folder "typed.json"
$TaskName = "Thread driver"
$Url = $Base.TrimEnd("/") + "/api/teams/messages/intake/thread-messages"
$null = New-Item -ItemType Directory -Force $Folder
Add-Type -AssemblyName System.Windows.Forms, UIAutomationClient, UIAutomationTypes
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class Win {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
"@

function Log([string]$text) {
  $line = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "  " + $text
  Write-Host $line
  try { Add-Content -Path $LogFile -Value $line -Encoding UTF8; $all = @(Get-Content $LogFile -Encoding UTF8); if ($all.Count -gt 400) { Set-Content -Path $LogFile -Value $all[-200..-1] -Encoding UTF8 } } catch { }
}
function Get-Key {
  if (-not (Test-Path $RelayKey)) { return $null }
  try { $s = ConvertTo-SecureString ((Get-Content $RelayKey -Raw).Trim()); return [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)) } catch { return $null }
}
function Web([string]$key) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $w = New-Object System.Net.WebClient
  $w.Headers["Authorization"] = "Bearer $key"; $w.Headers["User-Agent"] = "ThreadDriver/$Version"; $w.Encoding = [Text.Encoding]::UTF8
  return $w
}
function Report([string]$key, [string]$id, [string]$status, [string]$note, [string]$reply) {
  $body = @{ status = $status }; if ($note) { $body.note = $note }; if ($reply) { $body.reply = $reply }
  $w = Web $key; $w.Headers["Content-Type"] = "application/json"
  try { [void]$w.UploadString("$Url/$id", "POST", (ConvertTo-Json -InputObject $body -Compress)) } catch { if ($_.Exception.Message -notmatch "\(409\)") { throw } }
}
function Read-Json([string]$path) { if (-not (Test-Path -LiteralPath $path)) { return $null }; try { return ([IO.File]::ReadAllText($path) | ConvertFrom-Json) } catch { return $null } }

# ---- The thread, as the Claude desktop app records it ----
function Get-Session([string]$id) {
  $roots = @(Get-ChildItem -Path "$env:LOCALAPPDATA\Claude-Data\*\claude-code-sessions", "$env:APPDATA\Claude\claude-code-sessions" -Directory -ErrorAction SilentlyContinue)
  $f = $roots | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter "$id.json" -File -ErrorAction SilentlyContinue } | Select-Object -First 1
  if (-not $f) { return $null }
  return Read-Json $f.FullName
}
# Every thread on this PC that isn't archived (whatever its age), so Tyrone can be told to type into any of them.
function Send-Directory([string]$key) {
  $roots = @(Get-ChildItem -Path "$env:LOCALAPPDATA\Claude-Data\*\claude-code-sessions", "$env:APPDATA\Claude\claude-code-sessions" -Directory -ErrorAction SilentlyContinue)
  $epoch = New-Object DateTime(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
  $threads = @()
  foreach ($f in @($roots | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -Filter "local_*.json" -File -ErrorAction SilentlyContinue })) {
    $s = Read-Json $f.FullName
    if (-not $s -or $s.isArchived) { continue }
    $title = if ($s.title) { [string]$s.title } else { continue }
    $place = if ($s.writtenRepositories -and @($s.writtenRepositories).Count) { [string](@($s.writtenRepositories)[0]) } else { [string]$s.cwd }
    $threads += [ordered]@{ id = $f.BaseName; title = $title; folder = $(if ($place) { Split-Path $place -Leaf } else { "" }); lastActivityAt = $(if ($s.lastActivityAt) { $epoch.AddMilliseconds([double]$s.lastActivityAt).ToString("o") } else { "" }) }
  }
  $w = Web $key; $w.Headers["Content-Type"] = "application/json"
  [void]$w.UploadString("$Url/directory", "POST", (ConvertTo-Json -InputObject @{ threads = @($threads | Select-Object -First 300) } -Depth 4 -Compress))
  return $threads.Count
}

function Is-Busy($s) { return $s.latestUserFrameAt -and $s.lastTurnEdgeAt -and ([double]$s.latestUserFrameAt -gt [double]$s.lastTurnEdgeAt) }
# Its answer to our message: the newest assistant text after the message we typed (found by its words), or,
# when it can't be found, after the time we typed it (less a minute: a quick answer can beat the clock).
function Last-Answer($s, [DateTime]$after, [string]$sent = "") {
  $cli = if ($s.cliSessionId) { [string]$s.cliSessionId } else { [string]$s.lastAssistantCliSessionId }
  $dir = Join-Path (Join-Path $env:USERPROFILE ".claude\projects") (([string]$s.cwd) -replace '[^A-Za-z0-9]', '-')
  $file = Join-Path $dir "$cli.jsonl"
  if (-not (Test-Path -LiteralPath $file)) { return $null }
  $lines = @(Get-Content -LiteralPath $file -Tail 400 -Encoding UTF8)
  $mark = (($sent -replace '\s+', ' ').Trim()); $mark = $mark.Substring(0, [Math]::Min(40, $mark.Length))
  $latest = $null
  for ($i = $lines.Count - 1; $i -ge 0; $i--) {
    $o = try { $lines[$i] | ConvertFrom-Json } catch { $null }
    if (-not $o) { continue }
    if ($o.type -eq "user" -and $mark) {
      $said = if ($o.message.content -is [string]) { [string]$o.message.content } else { (@($o.message.content | Where-Object { $_.type -eq "text" } | ForEach-Object { [string]$_.text }) -join " ") }
      if ((($said -replace '\s+', ' ')).Contains($mark)) { return $latest }
    }
    if ($o.type -ne "assistant") { continue }
    $text = (@($o.message.content | Where-Object { $_.type -eq "text" } | ForEach-Object { [string]$_.text }) -join "`n").Trim()
    if ($text -and -not $latest) {
      if (-not $mark -and $o.timestamp -and [DateTime]::Parse([string]$o.timestamp).ToUniversalTime() -lt $after.ToUniversalTime().AddMinutes(-1)) { return $null }
      $latest = $text
    }
  }
  # Our message wasn't found in the last 400 lines: go by the time instead.
  if ($mark) { return (Last-Answer $s $after "") }
  return $latest
}

Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class Desk {
  [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool GetUserObjectInformation(IntPtr h, int index, StringBuilder info, int len, out int needed);
  [DllImport("user32.dll")] public static extern bool CloseDesktop(IntPtr h);
  public static string Name() { IntPtr h = OpenInputDesktop(0, false, 0x0001); if (h == IntPtr.Zero) return ""; var sb = new StringBuilder(256); int n; GetUserObjectInformation(h, 2, sb, 512, out n); CloseDesktop(h); return sb.ToString(); }
}
"@
# Typing needs a live, unlocked screen: not the lock screen, and not a Remote Desktop session that's disconnected.
function Is-Locked { return ([Desk]::Name() -ne "Default") }

# ---- Typing it in: open the thread, focus its box, paste, Enter ----
function Claude-Window { return (Get-Process -Name claude -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1) }
function Prompt-Box($h) {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle($h)
  $cond = New-Object System.Windows.Automation.AndCondition (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)), (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, "Prompt"))
  return $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
}
function Box-Text($box) {
  try { $tp = $box.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern); return ([string]$tp.DocumentRange.GetText(-1)).Trim() } catch { }
  try { $vp = $box.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern); return ([string]$vp.Current.Value).Trim() } catch { }
  return ""
}

# Types one message into a thread, then puts back the window that was in front (Tyrone, say), so you're
# returned to where you were. Returns $null when it went in, or why it didn't (and whether to try again later).
function Type-Into([string]$threadId, [string]$text) {
  $prev = [Win]::GetForegroundWindow()
  try { return (Type-IntoThread $threadId $text) }
  finally {
    $claude = Claude-Window
    if ($prev -ne [IntPtr]::Zero -and (-not $claude -or $prev -ne $claude.MainWindowHandle)) {
      Start-Sleep -Milliseconds 300
      foreach ($try in 1..5) {
        [Win]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [Win]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
        [void][Win]::SetForegroundWindow($prev); Start-Sleep -Milliseconds 200
        if ([Win]::GetForegroundWindow() -eq $prev) { break }
      }
    }
  }
}

function Type-IntoThread([string]$threadId, [string]$text) {
  if (Is-Locked) { return @{ wait = $true; why = "The PC is locked, or Remote Desktop to it is disconnected, so there's no screen to type on yet" } }
  $s = Get-Session $threadId
  if (-not $s) { return @{ wait = $false; why = "That thread isn't on this PC" } }
  if (Is-Busy $s) { return @{ wait = $true; why = "Waiting for the thread to finish what it's doing" } }
  $before = [double]$s.latestUserFrameAt
  Start-Process "claude://claude.ai/epitaxy/$threadId"
  Start-Sleep -Seconds 3
  $w = Claude-Window
  if (-not $w) { return @{ wait = $true; why = "The Claude app isn't open" } }
  if ([Win]::IsIconic($w.MainWindowHandle)) { [void][Win]::ShowWindow($w.MainWindowHandle, 9) }
  # Windows only lets a background program bring a window forward right after a key press; it can take a moment.
  $front = $false
  foreach ($try in 1..10) {
    [Win]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [Win]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [void][Win]::SetForegroundWindow($w.MainWindowHandle); Start-Sleep -Milliseconds 300
    if ([Win]::GetForegroundWindow() -eq $w.MainWindowHandle) { $front = $true; break }
  }
  if (-not $front) { return @{ wait = $true; why = "The Claude app couldn't be brought to the front, so nothing was typed" } }
  $box = $null
  foreach ($try in 1..10) { $box = Prompt-Box $w.MainWindowHandle; if ($box) { break }; Start-Sleep -Milliseconds 500 }
  if (-not $box) { return @{ wait = $false; why = "The thread opened, but its message box couldn't be found" } }
  if (Box-Text $box) { return @{ wait = $true; why = "There's unsent text in that thread's box; it won't be overwritten" } }
  # Typed key by key (pasting doesn't reach the app's box); a line break is Shift+Enter, so it doesn't send early.
  $want = (($text -replace "`r", "") -replace '\s+', ' ').Trim()
  $done = $false
  foreach ($attempt in 1..2) {
    $box.SetFocus()
    # The app is still settling after opening the thread: wait until the box has kept the focus a moment.
    Start-Sleep -Milliseconds (1000 * $attempt)
    if (-not $box.Current.HasKeyboardFocus -or [Win]::GetForegroundWindow() -ne $w.MainWindowHandle) { return @{ wait = $true; why = "The thread's box didn't keep the focus, so nothing was typed" } }
    $lines = ($text -replace "`r", "").Split("`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($i) { [System.Windows.Forms.SendKeys]::SendWait("+{ENTER}") }
      # One key per item (SendKeys' own characters escaped as {+}), sent 150 at a time.
      $keys = @($lines[$i].ToCharArray() | ForEach-Object { if ('+^%~(){}[]'.IndexOf($_) -ge 0) { "{" + $_ + "}" } else { [string]$_ } })
      for ($at = 0; $at -lt $keys.Count; $at += 150) {
        if ([Win]::GetForegroundWindow() -ne $w.MainWindowHandle) { return @{ wait = $false; why = "Another window took the focus while typing, so it wasn't sent; part of it may be in the thread's box" } }
        [System.Windows.Forms.SendKeys]::SendWait((-join $keys[$at..([Math]::Min($at + 149, $keys.Count - 1))]))
      }
    }
    Start-Sleep -Milliseconds 500
    $typed = ((Box-Text $box) -replace '\s+', ' ').Trim()
    if ($typed -eq $want) { $done = $true; break }
    # Some keys were lost: clear only what it typed (the box was empty before), then try once more.
    if ($typed -and $want.Contains($typed.Substring(0, [Math]::Min(40, $typed.Length))) -and [Win]::GetForegroundWindow() -eq $w.MainWindowHandle) {
      [System.Windows.Forms.SendKeys]::SendWait("^a"); Start-Sleep -Milliseconds 150; [System.Windows.Forms.SendKeys]::SendWait("{DELETE}"); Start-Sleep -Milliseconds 300
      if (Box-Text $box) { return @{ wait = $false; why = "Some of the message was lost while typing and it couldn't be cleared; it's in the thread's box, unsent" } }
    } else { return @{ wait = $false; why = "The message didn't land in the thread's box as typed, so nothing was sent" } }
  }
  if (-not $done) { return @{ wait = $false; why = "Keys kept getting lost while typing, so nothing was sent" } }
  if ([Win]::GetForegroundWindow() -ne $w.MainWindowHandle) { return @{ wait = $false; why = "Another window took the focus before it could be sent; the message is left in the thread's box, unsent" } }
  [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
  foreach ($try in 1..20) {
    Start-Sleep -Milliseconds 750
    $now = Get-Session $threadId
    if ($now -and [double]$now.latestUserFrameAt -gt $before) { return $null }
  }
  return @{ wait = $false; why = "It was pasted, but the thread didn't take it (check the thread's box)" }
}

# ---- The loop ----
function Get-Typed { $t = Read-Json $StateFile; if (-not $t) { return @{} }; $h = @{}; foreach ($p in $t.PSObject.Properties) { $h[$p.Name] = $p.Value }; return $h }
function Save-Typed($h) { [IO.File]::WriteAllText($StateFile, (ConvertTo-Json -InputObject $h -Depth 4), (New-Object Text.UTF8Encoding($false))) }

function Check([string]$key) {
  $messages = @(((Web $key).DownloadString($Url) | ConvertFrom-Json).messages)
  $typed = Get-Typed
  foreach ($m in $messages) {
    $id = [string]$m.id
    if ($m.status -eq "waiting" -and -not $typed.ContainsKey($id)) {
      $r = Type-Into ([string]$m.thread_id) ([string]$m.text)
      if (-not $r) {
        $typed[$id] = @{ thread = [string]$m.thread_id; at = (Get-Date).ToUniversalTime().ToString("o"); asked = "" }; Save-Typed $typed
        Report $key $id "typed" "Typed into the thread at $((Get-Date).ToString('h:mm tt'))" ""
        Log "Typed $id into $($m.thread_title)."
      } elseif ($r.wait -and ((Get-Date).ToUniversalTime() - [DateTime]::Parse([string]$m.created_at).ToUniversalTime()).TotalHours -lt 2) {
        if ($typed["note:$id"] -ne $r.why) { Report $key $id "waiting" $r.why ""; $typed["note:$id"] = $r.why; Save-Typed $typed; Log "$id waiting: $($r.why)" }
      } else {
        Report $key $id "failed" $r.why ""; Log "$id not typed: $($r.why)"
      }
      return   # one at a time: the app shows one thread
    }
    if ($m.status -eq "typed" -and $typed.ContainsKey($id)) {
      $entry = $typed[$id]
      $s = Get-Session ([string]$entry.thread)
      $since = [DateTime]::Parse([string]$entry.at)
      if (-not $s) { Report $key $id "failed" "The thread is gone from this PC" ""; $typed.Remove($id); Save-Typed $typed; continue }
      if (Is-Busy $s) {
        $needs = if ($s.interruptedAwaitingPerson) { "It's stopped and waiting on you (a question or a permission): answer it in the thread" } else { "" }
        if ($needs -and $entry.asked -ne $needs) { Report $key $id "typed" $needs ""; $entry.asked = $needs; Save-Typed $typed }
        if (((Get-Date).ToUniversalTime() - $since.ToUniversalTime()).TotalHours -gt 3) { Report $key $id "failed" "The thread was still going three hours later; its answer is in the thread" ""; $typed.Remove($id); Save-Typed $typed }
        continue
      }
      $answer = Last-Answer $s $since ([string]$m.text)
      if ($answer) { Report $key $id "replied" "" $answer; Log "$id answered."; $typed.Remove($id); $typed.Remove("note:$id"); Save-Typed $typed }
    }
  }
}

if ($Doctor) {
  Write-Host ("Relay key: " + $(if (Get-Key) { "found" } else { "missing: run ClaudeRelay.ps1 -Connect first" }))
  $w = Claude-Window
  Write-Host ("Claude app: " + $(if ($w) { "open" } else { "not open" }))
  if ($w) { Write-Host ("Message box found: " + $(if (Prompt-Box $w.MainWindowHandle) { "yes" } else { "no (open a thread in the app and try again)" })) }
  Write-Host ("PC locked: " + $(if (Is-Locked) { "yes" } else { "no" }))
  exit 0
}

if ($List) {
  $key = Get-Key
  if (-not $key) { Write-Host "Connect the Claude relay first: ClaudeRelay.ps1 -Connect" -ForegroundColor Yellow; exit 1 }
  Write-Host "Sent Tyrone the list of $(Send-Directory $key) threads."
  exit 0
}

if ($Type) {
  $r = Type-Into $Type $Message
  if ($r) { Write-Host "Not typed: $($r.why)" -ForegroundColor Yellow; exit 1 }
  Write-Host "Typed. Waiting for the thread's answer..." -ForegroundColor Green
  $since = (Get-Date).AddSeconds(-30)
  foreach ($i in 1..240) { Start-Sleep -Seconds 5; $s = Get-Session $Type; if ($s -and -not (Is-Busy $s)) { $a = Last-Answer $s $since $Message; if ($a) { Write-Host "Answer:`n$a"; exit 0 } } }
  Write-Host "No answer after 20 minutes." -ForegroundColor Yellow; exit 1
}

if ($Install) {
  if (-not (Get-Key)) { Write-Host "Connect the Claude relay first: ClaudeRelay.ps1 -Connect" -ForegroundColor Yellow; exit 1 }
  $self = Join-Path $Folder "ThreadDriver.ps1"
  if ($MyInvocation.MyCommand.Path -ne $self) { Copy-Item -LiteralPath $MyInvocation.MyCommand.Path -Destination $self -Force }
  $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$self`" -Base `"$Base`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description "Types Tyrone's messages into your Claude Code threads (Project Check-in). $self" -Force | Out-Null
  Start-ScheduledTask -TaskName $TaskName
  Log "Installed: starts at sign-in, running now."
  exit 0
}
if ($Uninstall) {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false }
  Log "Uninstalled."
  exit 0
}

$mutex = New-Object System.Threading.Mutex($false, "Local\ThreadDriver")
if (-not $mutex.WaitOne(0)) { Write-Host "The Thread driver is already running." -ForegroundColor Yellow; exit 0 }
Log "Thread driver $Version running: checking for messages every 10 seconds."
$last = ""; $nextList = Get-Date
while ($true) {
  $key = Get-Key
  if ($key -and (Get-Date) -ge $nextList) {
    try { $n = Send-Directory $key; if ($n -ne $script:listed) { Log "Sent Tyrone the list of $n threads."; $script:listed = $n } } catch { Log ("Thread list not sent: " + $_.Exception.Message) }
    $nextList = (Get-Date).AddMinutes(2)
  }
  $note = if (-not $key) { "Not connected: run ClaudeRelay.ps1 -Connect" } else { try { Check $key; "" } catch { "Not checked: " + $_.Exception.Message } }
  if ($note -ne $last) { if ($note) { Log $note }; $last = $note }
  Start-Sleep -Seconds 10
}
