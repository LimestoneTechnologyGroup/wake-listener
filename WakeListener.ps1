# Wake listener: say "hey Tyrone" and your Project Check-in assistant opens.
#
# Plain PowerShell, no exe. It learns YOUR voice saying the phrase: the first
# time it runs it asks you to say "hey Tyrone" a few times, then compares
# everything the microphone hears with those recordings (VoiceMatch.cs, next to
# this file). No speech recognizer, nothing sent anywhere; the recordings stay in
# %APPDATA%\WakeListener\voice. When it hears the phrase, it opens the
# assistant's voice page, which starts talking.
#
# The window shows what's going on: which microphone, a live level meter, and
# every bit of talking it hears with how close it was to your phrase.
#
# Run it: double-click "Start wake listener.cmd". Quit from the tray icon.
# Check it without a microphone: WakeListener.ps1 -Test

param([switch]$Test)

$Version = "5.0.0"

# ---- Settings ---------------------------------------------------------------
$Phrase        = "hey Tyrone"   # what you'll say (training asks you to say this)
$Url           = "https://project-checkin.dev.limestonetg.com/assistant?start=voice&close=1"   # close=1: the window closes itself once the conversation is saved
$Browser       = "edge-app"     # edge-app, chrome-app, or default
# How easily it opens. 1.0 is what training worked out from your recordings.
# Raise it (1.1, 1.2) if it misses you; lower it (0.9) if it opens by mistake.
$Sensitivity   = 1.0
$VoiceFolder   = Join-Path $env:APPDATA "WakeListener\voice"
$TrainSays     = 8              # how many times training asks for the phrase
# While the assistant's window is open, the phrase is ignored (so it never opens
# twice); it's found by its title. Also ignored for a few seconds after opening,
# while the page loads and has no title yet.
$AssistantTitle = "Assistant ·"
$GraceSecs     = 15
# -----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Speech
Add-Type -Path (Join-Path $PSScriptRoot "VoiceMatch.cs") -ReferencedAssemblies System.Speech

# Windows' default recording device: its name and id, and its live level, from the Core Audio API.
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
namespace WakeListenerAudio {
  [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumerator {
    int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
  }
  [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDevice {
    int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    int OpenPropertyStore(int access, out IPropertyStore store);
    int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
  }
  [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IPropertyStore {
    int GetCount(out int count);
    int GetAt(int index, out PropertyKey key);
    int GetValue(ref PropertyKey key, out PropVariant value);
  }
  [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioMeterInformation { int GetPeakValue(out float peak); }
  [StructLayout(LayoutKind.Sequential)] struct PropertyKey { public Guid fmtid; public int pid; }
  [StructLayout(LayoutKind.Explicit)] struct PropVariant { [FieldOffset(0)] public short vt; [FieldOffset(8)] public IntPtr pointer; [FieldOffset(8)] public long padding; }
  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }
  public static class DefaultMicrophone {
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant value);
    static IMMDevice Device() {
      var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
      IMMDevice device;
      return enumerator.GetDefaultAudioEndpoint(1, 0, out device) == 0 ? device : null;
    }
    /// <summary>"id|name" of the default recording device, or "" when there is none.</summary>
    public static string Describe() {
      try {
        var device = Device();
        if (device == null) return "";
        string id; device.GetId(out id);
        IPropertyStore store;
        string name = "Unnamed microphone";
        if (device.OpenPropertyStore(0, out store) == 0) {
          var key = new PropertyKey { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };
          PropVariant value;
          if (store.GetValue(ref key, out value) == 0) {
            if (value.vt == 31) name = Marshal.PtrToStringUni(value.pointer);
            PropVariantClear(ref value);
          }
        }
        return id + "|" + name;
      } catch { return ""; }
    }
    static string meterId;
    static IAudioMeterInformation meter;
    /// <summary>The default microphone's live level, 0 to 100 (Windows' own meter), or -1 when there's none.</summary>
    public static int Level() {
      try {
        var device = Device();
        if (device == null) return -1;
        string id; device.GetId(out id);
        if (meter == null || id != meterId) {
          var iid = new Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064");
          object o;
          if (device.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) return -1;
          meter = (IAudioMeterInformation)o; meterId = id;
        }
        float peak; meter.GetPeakValue(out peak);
        return (int)Math.Round(Math.Min(1f, Math.Max(0f, peak)) * 100);
      } catch { meter = null; return -1; }
    }
  }
}
'@

function Get-Microphone {
  if ($env:WAKE_LISTENER_FAKE_MIC) { return [pscustomobject]@{ Id = "test"; Name = "Test recording" } }
  $d = [WakeListenerAudio.DefaultMicrophone]::Describe()
  if (-not $d) { return $null }
  $i = $d.IndexOf("|")
  return [pscustomobject]@{ Id = $d.Substring(0, $i); Name = $d.Substring($i + 1) }
}

function New-ClipList { return ,(New-Object 'System.Collections.Generic.List[System.Int16[]]') }

if ($Test) {
  # Windows' own voices stand in for you: train on some "hey Tyrone"s and some
  # ordinary talk, then check new ones open and other talk doesn't, through the
  # same path the microphone's sound takes.
  $ok = $true
  $voices = [WakeVoice.TestKit]::Voices()
  if (-not $voices) { "no Windows voices installed: can't run the voice checks"; exit 1 }
  $a = $voices[0]; $b = if ($voices.Count -gt 1) { $voices[1] } else { $voices[0] }
  "voices: " + ($voices -join ", ")
  $seed = 1
  function Capture($text, $voice, $rate) {
    $l = New-Object WakeVoice.Listener; $l.Training = $true
    $null = [WakeVoice.TestKit]::Hear($l, [WakeVoice.TestKit]::Say($text, $voice, $rate, ($script:seed++)))
    $out = @(); $c = $null; while ($l.Captured.TryDequeue([ref]$c)) { $out += ,$c }; return ,$out
  }
  $said = New-ClipList; $talk = New-ClipList
  foreach ($p in @(@($a,-2),@($a,0),@($a,2),@($b,-1),@($b,1),@($a,1),@($b,0),@($b,-2))) { foreach ($c in (Capture $Phrase $p[0] $p[1])) { $said.Add($c) } }
  foreach ($t in @("Can you send the budget numbers over to finance before lunch.", "I think the meeting moved to Thursday afternoon.", "Hey, how is the permit coming along.", "Tyrone said the trucks are running late today.", "Let's try to get the tile finished this week.", "Remind me to call the county about the inspection.")) {
    foreach ($v in @($a, $b)) { foreach ($c in (Capture $t $v 0)) { $talk.Add($c) } }
  }
  "training: $($said.Count) phrase recordings, $($talk.Count) bits of ordinary talk"
  if ($said.Count -ne 8) { "training: expected 8 phrase recordings   <-- WRONG"; $ok = $false }
  # Saved and loaded back, as the listener does at start-up.
  $folder = Join-Path ([IO.Path]::GetTempPath()) ("wake-listener-test-" + [guid]::NewGuid())
  $null = New-Item -ItemType Directory $folder
  for ($i = 0; $i -lt $said.Count; $i++) { [WakeVoice.Wav]::Write((Join-Path $folder ("said_{0:00}.wav" -f $i)), $said[$i]) }
  for ($i = 0; $i -lt $talk.Count; $i++) { [WakeVoice.Wav]::Write((Join-Path $folder ("talk_{0:00}.wav" -f $i)), $talk[$i]) }
  $voice = [WakeVoice.Wav]::Load($folder)
  Remove-Item -Recurse -Force $folder
  "voice: " + $voice.Report
  # A recording that isn't the phrase (here, other words) is left out.
  $withBad = New-ClipList; foreach ($c in $said) { $withBad.Add($c) }
  foreach ($c in (Capture "turn on the lights please" $a 0)) { $withBad.Add($c) }
  $report = [WakeVoice.Voice]::Train($withBad, $talk).Report
  "bad recording: " + $(if ($report -match "1 recording didn't sound like the others") { "left out" } else { "KEPT   <-- WRONG ($report)" })
  if ($report -notmatch "1 recording didn't sound like the others") { $ok = $false }
  $l = New-Object WakeVoice.Listener; $l.Voice = $voice
  $checks = @(
    @($Phrase, $a, -1, $true), @($Phrase, $b, 2, $true), @($Phrase, $a, 3, $true), @($Phrase, $b, -3, $true),
    @("$Phrase, what's on my calendar today", $a, 0, $true),
    @("Tyrone called about the permit yesterday", $a, 0, $false), @("hey how are you", $b, 0, $false),
    @("send the budget to finance", $a, 0, $false), @("turn on the lights", $b, 0, $false),
    @("hey there Ron", $a, 0, $false), @("hey, I don't know", $b, 0, $false), @("high tone", $a, 0, $false))
  foreach ($t in $checks) {
    $events = [WakeVoice.TestKit]::Hear($l, [WakeVoice.TestKit]::Say($t[0], $t[1], $t[2], ($seed++)))
    $woke = @($events | Where-Object { $_ -like "wake|*" }).Count -gt 0
    $best = ($events | ForEach-Object { [int]$_.Split("|")[1] } | Measure-Object -Maximum).Maximum
    "{0,-8} {1,4}%  {2}{3}" -f $(if ($woke) { "opens" } else { "ignored" }), $best, ("`"" + $t[0] + "`" (" + $t[1].Split(" ")[1] + ", speed " + $t[2] + ")"), $(if ($woke -ne $t[3]) { "   <-- WRONG" } else { "" })
    $ok = $ok -and ($woke -eq $t[3])
  }
  $mic = Get-Microphone
  "microphone: " + $(if ($mic) { $mic.Name } else { "none on this PC" })
  try { $m = New-Object WakeVoice.Listener; $m.Start(); Start-Sleep -Seconds 1; $m.Stop(); "listening: opened and closed the microphone" }
  catch { $why = $_.Exception; while ($why.InnerException) { $why = $why.InnerException }; "listening: " + $why.Message + $(if (-not $mic) { " (expected: no microphone here)" } else { "" }); if ($mic) { $ok = $false } }
  if ($ok) { exit 0 } else { exit 1 }
}

function Open-Assistant {
  if ($env:WAKE_LISTENER_FAKE_MIC) { Write-Host "(test run: the assistant would open now)"; return }
  $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  $chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  # An app-style window: no tabs or address bar, and the browser lets it start talking straight away.
  if ($Browser -eq "edge-app" -and $edge) { Start-Process $edge "--app=$Url" }
  elseif ($Browser -eq "chrome-app" -and $chrome) { Start-Process $chrome "--app=$Url" }
  else { Start-Process $Url }
}

# ---- The window -------------------------------------------------------------
function Width { try { [Math]::Max(40, [Console]::WindowWidth - 1) } catch { 79 } }
$script:meterShown = $false
function Clear-Meter { if ($script:meterShown) { [Console]::Write("`r" + (" " * (Width)) + "`r"); $script:meterShown = $false } }
function Say([string]$text, [string]$color = "Gray") {
  Clear-Meter
  Write-Host ("{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $text) -ForegroundColor $color
  if ($color -eq "Yellow" -or $color -eq "Red") { Notify $text }
}
$script:listener = $null
$script:windowLoudest = 0
function Show-Meter {
  # While listening: what the listener itself receives. Otherwise Windows' own meter.
  $level = if ($script:listener) { $script:listener.TakePeak() } else { [WakeListenerAudio.DefaultMicrophone]::Level() }
  if ($level -gt $script:windowLoudest) { $script:windowLoudest = $level }
  $state = if ($level -lt 0) { "no microphone" } elseif (-not $script:listener) { "not listening" } elseif ($level -ge 15) { "hearing sound" } else { "quiet" }
  $shown = [Math]::Max(0, $level)
  $bars = [Math]::Round($shown / 100 * 30)
  $line = "  Mic level [" + ("#" * $bars).PadRight(30, ".") + "] " + ("{0,3}" -f $shown) + "   " + $state
  [Console]::Write("`r" + $line.PadRight((Width)).Substring(0, (Width)))
  $script:meterShown = $true
}

# ---- The tray icon ----------------------------------------------------------
# It lives next to the clock and keeps listening whatever window is in front.
# The activity window (meter and log) starts hidden; the tray menu shows it.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace WakeListenerWindow -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int show);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
'@
# Is the assistant open? A visible Edge or Chrome window whose title contains $AssistantTitle.
Add-Type -Language CSharp @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
namespace WakeListenerWindows {
  public static class Browser {
    delegate bool EnumProc(IntPtr window, IntPtr param);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr param);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int max);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    public static bool HasWindow(string titlePart) {
      bool found = false;
      EnumWindows((w, p) => {
        if (!IsWindowVisible(w)) return true;
        var text = new StringBuilder(512);
        GetWindowText(w, text, text.Capacity);
        if (text.ToString().IndexOf(titlePart, StringComparison.OrdinalIgnoreCase) < 0) return true;
        uint pid; GetWindowThreadProcessId(w, out pid);
        try {
          var name = Process.GetProcessById((int)pid).ProcessName.ToLowerInvariant();
          if (name == "msedge" || name == "chrome") { found = true; return false; }
        } catch { }
        return true;
      }, IntPtr.Zero);
      return found;
    }
  }
}
'@
function Test-AssistantOpen { try { [WakeListenerWindows.Browser]::HasWindow($AssistantTitle) } catch { $false } }

$script:consoleWindow = [WakeListenerWindow.Native]::GetConsoleWindow()
$script:windowShown = $true
function Set-WindowShown([bool]$show) {
  $script:windowShown = $show
  [void][WakeListenerWindow.Native]::ShowWindow($script:consoleWindow, $(if ($show) { 9 } else { 0 }))
  if ($show) { [void][WakeListenerWindow.Native]::SetForegroundWindow($script:consoleWindow) }
  $script:showItem.Text = if ($show) { "Hide activity window" } else { "Show activity window" }
}
$script:paused = $false
$script:quit = $false
$script:trainRequested = $false
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Icon = [System.Drawing.SystemIcons]::Information
$script:tray.Visible = $true
$script:showItem = New-Object System.Windows.Forms.MenuItem("Show activity window")
$script:showItem.add_Click({ Set-WindowShown (-not $script:windowShown) })
$pauseItem = New-Object System.Windows.Forms.MenuItem("Pause listening")
$pauseItem.add_Click({ $script:paused = -not $script:paused; $this.Text = if ($script:paused) { "Resume listening" } else { "Pause listening" }; Say $(if ($script:paused) { "Paused: it won't open the assistant until you resume." } else { "Resumed." }); Set-TrayText })
$trainItem = New-Object System.Windows.Forms.MenuItem("Teach it my voice again")
$trainItem.add_Click({ $script:trainRequested = $true })
$openItem = New-Object System.Windows.Forms.MenuItem("Open the assistant now")
$openItem.add_Click({ try { Open-Assistant } catch { } })
$quitItem = New-Object System.Windows.Forms.MenuItem("Quit (stop listening)")
$quitItem.add_Click({ $script:quit = $true })
$script:tray.ContextMenu = New-Object System.Windows.Forms.ContextMenu(,[System.Windows.Forms.MenuItem[]]@($script:showItem, $pauseItem, $trainItem, $openItem, (New-Object System.Windows.Forms.MenuItem("-")), $quitItem))
$script:tray.add_DoubleClick({ Set-WindowShown $true })
$script:lastHeard = ""
function Set-TrayText {
  $micName = if ($script:micName) { $script:micName } else { "no microphone" }
  $text = $(if ($script:paused) { "Wake listener: paused" } else { "Wake listener: listening" }) + "`n" + $micName + $(if ($script:lastHeard) { "`nLast: " + $script:lastHeard } else { "" })
  $script:tray.Text = if ($text.Length -gt 63) { $text.Substring(0, 63) } else { $text }
}
$script:lastBalloon = [datetime]::MinValue
function Notify([string]$text) {
  if ($script:windowShown -or ((Get-Date) - $script:lastBalloon).TotalSeconds -lt 60) { return }
  $script:lastBalloon = Get-Date
  $script:tray.ShowBalloonTip(8000, "Wake listener", $text, [System.Windows.Forms.ToolTipIcon]::Warning)
}
# Waits, keeping the tray menu responsive and the meter moving.
function Idle([int]$ms) { $until = (Get-Date).AddMilliseconds($ms); while ((Get-Date) -lt $until -and -not $script:quit) { [System.Windows.Forms.Application]::DoEvents(); Show-Meter; Start-Sleep -Milliseconds 100 } }

# ---- Listening --------------------------------------------------------------
$script:voice = $null
function Start-Listening {
  Stop-Listening
  $l = New-Object WakeVoice.Listener
  $l.Voice = $script:voice
  $l.Sensitivity = $Sensitivity
  $l.Start()
  $script:listener = $l
}
function Stop-Listening {
  $l = $script:listener; $script:listener = $null
  if ($l) { try { $l.Stop() } catch { } }
}
function Why($err) { $e = $err.Exception; while ($e.InnerException) { $e = $e.InnerException }; return $e.Message }

# Waits up to $secs for the next bit of talking while training; $null if none.
function Wait-Talk($l, [int]$secs) {
  $until = (Get-Date).AddSeconds($secs)
  $clip = $null
  while ((Get-Date) -lt $until -and -not $script:quit) {
    if ($l.Captured.TryDequeue([ref]$clip)) { return ,$clip }
    Idle 100
  }
  return $null
}

# Training: you say the phrase a few times, then read a few sentences out loud.
# Returns $true when it has learned your voice.
function Train-Voice {
  Stop-Listening
  Set-WindowShown $true
  $l = New-Object WakeVoice.Listener; $l.Training = $true
  try { $l.Start(); $script:lastTrainError = $null } catch {
    $why = Why $_
    if ($why -ne $script:lastTrainError) { Say ("Couldn't open the microphone to learn your voice: " + $why + " Trying again every 20 seconds.") Red }
    $script:lastTrainError = $why
    return $false
  }
  $script:listener = $l
  Write-Host ""
  Say "Teaching it your voice: about a minute. Use the microphone you'll use day to day, in your normal voice." White
  try {
    Say "Getting the room's background level: stay quiet for two seconds." DarkGray
    Idle 2000
    $clip = $null; while ($l.Captured.TryDequeue([ref]$clip)) { }
    $said = New-ClipList
    $misses = 0
    while ($said.Count -lt $TrainSays -and -not $script:quit) {
      Say ("Say `"$Phrase`" now ({0} of {1}), then pause." -f ($said.Count + 1), $TrainSays) Cyan
      $clip = Wait-Talk $l 10
      if ($null -eq $clip) {
        $misses++
        if ($misses -ge 3) { Say "It isn't hearing you: check the meter moves when you talk, and the microphone isn't muted. Choose 'Teach it my voice again' from the tray icon to retry." Yellow; return $false }
        Say "Didn't hear anything. Check the meter moves when you talk." DarkYellow
        continue
      }
      $misses = 0
      $secs = $clip.Length / 16000.0
      if ($secs -gt 2.6) { Say ("That was {0:0.0} seconds of talking: say just `"$Phrase`" on its own, then pause." -f $secs) DarkYellow; continue }
      if ($secs -lt 0.4) { Say "That was too short to be the phrase: try again." DarkYellow; continue }
      $said.Add($clip)
      Say ("Got it ({0:0.0} seconds)." -f $secs) Green
      Idle 500
      while ($l.Captured.TryDequeue([ref]$clip)) { }
    }
    if ($script:quit) { return $false }
    Write-Host ""
    Say "Now read this out loud in your normal voice, so it learns what ISN'T the phrase (about 20 seconds):" Cyan
    Write-Host ""
    Write-Host "    This morning I checked on the permit for the new site. Tyrone from the county" -ForegroundColor White
    Write-Host "    says the inspection moved to Thursday, so let's get the budget over to finance" -ForegroundColor White
    Write-Host "    before lunch. Hey, can you also call the crew about the tile and the trucks?" -ForegroundColor White
    Write-Host "    I'd like the schedule updated by the end of the day, if that's all right." -ForegroundColor White
    Write-Host ""
    $talk = New-ClipList
    $until = (Get-Date).AddSeconds(30)
    $heardAny = $false
    while ((Get-Date) -lt $until -and -not $script:quit) {
      $clip = Wait-Talk $l 1
      if ($null -ne $clip) { $talk.Add($clip); $heardAny = $true; Say ("Heard {0:0.0} seconds." -f ($clip.Length / 16000.0)) DarkGray }
      # Done once it has a good amount and you've stopped.
      if ($talk.Count -ge 4 -and ($talk | ForEach-Object { $_.Length } | Measure-Object -Sum).Sum -ge 16000 * 12 -and $null -eq $clip -and ((Get-Date) -gt $until.AddSeconds(-24))) {
        $more = Wait-Talk $l 3
        if ($null -eq $more) { break } else { $talk.Add($more) }
      }
    }
    if (-not $heardAny) { Say "Didn't hear the reading; it'll learn from the phrase alone, which may open by mistake more often." DarkYellow }
  } finally {
    Stop-Listening
  }

  # Keep the recordings (replacing any earlier ones) and learn from them.
  $null = New-Item -ItemType Directory -Force $VoiceFolder
  Get-ChildItem $VoiceFolder -Filter "*.wav" | Remove-Item -Force
  for ($i = 0; $i -lt $said.Count; $i++) { [WakeVoice.Wav]::Write((Join-Path $VoiceFolder ("said_{0:00}.wav" -f $i)), $said[$i]) }
  for ($i = 0; $i -lt $talk.Count; $i++) { [WakeVoice.Wav]::Write((Join-Path $VoiceFolder ("talk_{0:00}.wav" -f $i)), $talk[$i]) }
  try { $script:voice = [WakeVoice.Voice]::Train($said, $talk) } catch { Say ("Couldn't learn from those recordings: " + (Why $_)) Red; return $false }
  Say ("Learned your voice. " + $script:voice.Report) Green
  Say "Try it: say `"$Phrase`" (each try shows how close it was; 100% opens)." White
  return $true
}

# ---- Start ------------------------------------------------------------------
Clear-Host
Write-Host "Wake listener $Version" -ForegroundColor White
Write-Host "Say `"$Phrase`" and your assistant opens. It knows your voice from your recordings."
Write-Host "Opens: $Url"
Write-Host "This window hides itself: the tray icon by the clock keeps listening, whatever window is in front."
Write-Host "Right-click the tray icon to show this window again, pause, teach it your voice again, or quit."
Write-Host "(If you click inside this window it pauses until you press Esc.)"
Write-Host ""
Set-TrayText
try { $script:voice = [WakeVoice.Wav]::Load($VoiceFolder) } catch { Say ("Couldn't read your saved voice: " + (Why $_) + " It will ask you to record it again.") Yellow }
$needTraining = -not $script:voice
if ($needTraining) {
  Say "First run: it needs to learn your voice before it can listen." White
} else {
  Say ("Your voice: " + $script:voice.Report) DarkGray
  Idle 2500
  Set-WindowShown $false
  $script:tray.ShowBalloonTip(6000, "Wake listener is on", "Say `"$Phrase`" and your assistant opens. It's listening in the tray; right-click the icon for options.", [System.Windows.Forms.ToolTipIcon]::Info)
}

$mic = $null
$last = [datetime]::MinValue
$since = Get-Date
$quietWarned = $false
$nextMicCheck = Get-Date
$restartAt = $null
$nextTrainTry = Get-Date
# While the assistant is open it has the microphone: the listener lets go of it,
# and opens it afresh a couple of seconds after the assistant closes (a Bluetooth
# headset switches modes in between).
$handedOver = $false
$nextWindowCheck = Get-Date

while (-not $script:quit) {
  # Learning your voice: on the first run, and when asked from the tray.
  if (($needTraining -and (Get-Date) -ge $nextTrainTry) -or $script:trainRequested) {
    $script:trainRequested = $false
    if (-not $handedOver) {
      if (Train-Voice) { $needTraining = $false } else { $needTraining = -not $script:voice; $nextTrainTry = (Get-Date).AddSeconds(20) }
      $restartAt = Get-Date
    }
  }

  # Every second: is the assistant open? Let go of the mic while it is; listen afresh when it closes.
  if ((Get-Date) -ge $nextWindowCheck) {
    $nextWindowCheck = (Get-Date).AddSeconds(1)
    $open = (Test-AssistantOpen) -or (((Get-Date) - $last).TotalSeconds -lt $GraceSecs)
    if ($open -and -not $handedOver) {
      $handedOver = $true
      Stop-Listening
      Say "The assistant is open: not listening until it closes." DarkGray
      $script:lastHeard = "assistant open"; Set-TrayText
    } elseif (-not $open -and $handedOver) {
      $handedOver = $false
      Say "The assistant closed: listening again in a moment."
      $script:lastHeard = (Get-Date -Format "HH:mm") + " last call"; Set-TrayText
      $restartAt = (Get-Date).AddSeconds(2)
    }
  }
  if ($handedOver -or $needTraining) {
    [System.Windows.Forms.Application]::DoEvents(); Show-Meter; Start-Sleep -Milliseconds 100
    continue
  }

  # Every few seconds: follow the default microphone, (re)opening it whenever it changes.
  if ((Get-Date) -ge $nextMicCheck -or ($restartAt -and (Get-Date) -ge $restartAt)) {
    $nextMicCheck = (Get-Date).AddSeconds(3)
    $now = Get-Microphone
    if (-not $now) {
      if ($mic -or -not $script:noMicSaid) { Say "No microphone found. Plug one in or set a default in Settings > System > Sound > Input. Checking every few seconds." Yellow; $script:noMicSaid = $true }
      Stop-Listening; $mic = $null
      $script:micName = $null; Set-TrayText
    } else {
      $script:noMicSaid = $false
      $due = $restartAt -and (Get-Date) -ge $restartAt
      if (-not $script:listener -or -not $mic -or $now.Id -ne $mic.Id -or $due) {
        if ($mic -and $now.Id -ne $mic.Id) { Say "The default microphone changed. (If it's a different kind of mic, teaching it your voice again on it helps.)" }
        $mic = $now; $restartAt = $null
        try {
          Start-Listening
          Say ("Listening on: " + $mic.Name) Green
          $script:micName = $mic.Name; Set-TrayText
          $host.UI.RawUI.WindowTitle = "Wake listener: listening on " + $mic.Name
          $since = Get-Date; $script:windowLoudest = 0; $quietWarned = $false
          $script:lastStartError = $null
        } catch {
          $why = Why $_
          if ($why -ne $script:lastStartError) { Say ("Couldn't open the microphone: " + $why + " Trying again every few seconds.") Red }
          $script:lastStartError = $why
          Stop-Listening
          $restartAt = (Get-Date).AddSeconds(5)
        }
      }
    }
  }

  # The microphone stopped delivering sound (a Bluetooth headset switching modes, say): open it afresh.
  if ($script:listener -and $script:listener.SecondsSinceSound -gt 3) {
    Say "The microphone stopped sending sound: opening it again." DarkYellow
    Stop-Listening
    $restartAt = Get-Date
  }

  # What it heard, from the listener's queue.
  $item = $null
  while ($script:listener -and $script:listener.Events.TryDequeue([ref]$item)) {
    $parts = $item.Split("|")
    if ($parts[0] -ne "wake" -and $parts[0] -ne "heard") { continue }
    $close = [int]$parts[1]; $secs = $parts[2]
    $about = "$secs s of talking, $close% like your `"$Phrase`""
    if ($parts[0] -eq "heard") {
      if ($close -ge 85) { Say "Heard $about (opens at 100%): close. If that was you saying it, raise `$Sensitivity a little, or teach it your voice again." DarkYellow }
      else { Say "Heard $about." DarkGray }
    } elseif (((Get-Date) - $last).TotalSeconds -lt $GraceSecs) {
      Say "Heard $about`: it's opening now, ignored." DarkGray
    } elseif (Test-AssistantOpen) {
      Say "Heard $about`: the assistant is already open, ignored." DarkGray
    } elseif ($script:paused) {
      Say "Heard $about`: paused, so not opening." DarkGray
    } else {
      Say "Heard $about`: opening the assistant." Cyan
      $script:lastHeard = (Get-Date -Format "HH:mm") + " opened"; Set-TrayText
      $last = Get-Date
      # Let go of the microphone first, so the assistant gets it cleanly.
      Stop-Listening
      $handedOver = $true
      Say "The assistant is open: not listening until it closes." DarkGray
      try { Open-Assistant } catch { Say ("Couldn't open the assistant: " + $_.Exception.Message) Red }
      break
    }
  }
  if ($handedOver) { continue }

  # Silent too long: say so once (the meter should move when you talk).
  if ($script:listener -and ((Get-Date) - $since).TotalSeconds -ge 20) {
    if ($script:windowLoudest -lt 3 -and -not $quietWarned) { Say ("No sound at all from " + $mic.Name + " for 20 seconds: check its mute button and its input volume (Settings > System > Sound > Input).") Yellow; $quietWarned = $true }
    if ($script:windowLoudest -ge 3) { $quietWarned = $false }
    $script:windowLoudest = 0; $since = Get-Date
  }

  [System.Windows.Forms.Application]::DoEvents()
  Show-Meter
  Start-Sleep -Milliseconds 100
}

# Quit from the tray: tidy up.
Stop-Listening
$script:tray.Visible = $false
$script:tray.Dispose()
