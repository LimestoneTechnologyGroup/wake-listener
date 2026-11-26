# Wake listener: say "hey Tyrone" and your Project Check-in assistant opens.
#
# Plain PowerShell, no exe. The listening is done by listen.py (next to this
# file) with sherpa-onnx keyword spotting: a small neural model trained on
# thousands of hours of speech, so it hears the phrase from across the room and
# over music, in anyone's voice, with nothing to train. It runs on this PC;
# nothing is sent anywhere. The first run sets it up (Python, the engine and its
# 17 MB model, in %LOCALAPPDATA%\WakeListener). When it hears the phrase it opens
# the assistant's voice page, which starts talking.
#
# The window shows what's going on: which microphone, a live level meter, and
# each time it hears the phrase.
#
# Run it: double-click "Start wake listener.cmd". Quit from the tray icon.
# Check it without a microphone: WakeListener.ps1 -Test

param([switch]$Test)

$Version = "6.0.0"

# ---- Settings ---------------------------------------------------------------
$Phrase        = "hey Tyrone"   # what you'll say (two or three words work best)
$Url           = "https://project-checkin.dev.limestonetg.com/assistant?start=voice&close=1"   # close=1: the window closes itself once the conversation is saved
$Browser       = "edge-app"     # edge-app, chrome-app, or default
# How easily it opens: low, normal or high. Also on the tray icon's menu, which remembers your choice.
$Sensitivity   = "normal"
$EngineFolder  = Join-Path $env:LOCALAPPDATA "WakeListener"
# While the assistant's window is open, the phrase is ignored (so it never opens
# twice); it's found by its title. Also ignored for a few seconds after opening,
# while the page loads and has no title yet.
$AssistantTitle = "Assistant ·"
$GraceSecs     = 15
# The engine's packages, at versions tested with this release.
$Packages      = @("sherpa-onnx==2.0.3", "sounddevice==0.5.6", "numpy==2.5.5", "sentencepiece==0.2.3")
# -----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"
$ListenPy = Join-Path $PSScriptRoot "listen.py"
$VenvPython = Join-Path $EngineFolder "py\Scripts\python.exe"
$SettingsFile = Join-Path $EngineFolder "settings.txt"
try { $saved = (Get-Content $SettingsFile -ErrorAction Stop | Where-Object { $_ -match "^sensitivity=" }) -replace "^sensitivity=", ""; if ($saved -in @("low", "normal", "high")) { $Sensitivity = $saved } } catch { }

# listen.py as a child process: its output lines, read in the background, one event each.
Add-Type -Language CSharp @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
namespace WakeListenerEngine {
  public class Ears {
    public readonly ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
    Process p;
    public bool Running { get { try { return p != null && !p.HasExited; } catch { return false; } } }
    public void Start(string python, string args) {
      var info = new ProcessStartInfo(python, args) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
      info.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8";
      info.EnvironmentVariables["PYTHONUNBUFFERED"] = "1";
      p = new Process { StartInfo = info, EnableRaisingEvents = true };
      p.OutputDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue(e.Data); };
      p.ErrorDataReceived += (s, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) Lines.Enqueue("stderr|" + e.Data); };
      p.Start();
      p.BeginOutputReadLine();
      p.BeginErrorReadLine();
    }
    public void Stop() {
      var q = p; p = null;
      if (q == null) return;
      try { if (!q.HasExited) { q.Kill(); q.WaitForExit(3000); } } catch { }
      q.Dispose();
    }
  }
}
'@

# Windows' default recording device: its name and id, and its live level, from the Core Audio API.
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

if ($Test) {
  # Windows' own voices say the phrase and other things, with room hiss, and
  # music under some; each recording goes through listen.py the way the
  # microphone's sound does. The phrase must open; other talk mustn't.
  if (-not (Test-Path $VenvPython)) { "engine: not set up in $EngineFolder; start the wake listener once to set it up"; exit 1 }
  Add-Type -AssemblyName System.Speech
  $ok = $true
  $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $voices = @($synth.GetInstalledVoices() | Where-Object { $_.Enabled } | ForEach-Object { $_.VoiceInfo.Name })
  if (-not $voices) { "no Windows voices installed: can't run the voice checks"; exit 1 }
  "voices: " + ($voices -join ", ")
  $a = $voices[0]; $b = if ($voices.Count -gt 1) { $voices[1] } else { $voices[0] }
  $fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
  $folder = Join-Path ([IO.Path]::GetTempPath()) ("wake-listener-test-" + [guid]::NewGuid())
  $null = New-Item -ItemType Directory $folder
  $rnd = New-Object System.Random 7
  # A recording: a second of room either side, hiss throughout, and optionally a loud chord-and-drum backing.
  function Clip([string]$text, [string]$voice, [int]$rate, [bool]$music, [string]$path) {
    $ms = New-Object System.IO.MemoryStream
    $synth.SelectVoice($voice); $synth.Rate = $rate
    $synth.SetOutputToAudioStream($ms, $fmt); $synth.Speak($text); $synth.SetOutputToNull()
    $bytes = $ms.ToArray()
    $n = $bytes.Length / 2 + 32000
    $out = New-Object byte[] ($n * 2)
    $root = 110 * [Math]::Pow(2, $rnd.Next(0, 12) / 12)
    for ($i = 0; $i -lt $n; $i++) {
      $j = $i - 16000
      $x = $(if ($j -ge 0 -and $j -lt $bytes.Length / 2) { [BitConverter]::ToInt16($bytes, $j * 2) * 0.6 } else { 0 }) + ($rnd.NextDouble() - 0.5) * 80
      if ($music) {
        if ($i % 8000 -eq 0) { $root = 110 * [Math]::Pow(2, $rnd.Next(0, 12) / 12) }
        $t = $i / 16000.0
        $x += 1500 * ([Math]::Sin(2 * [Math]::PI * $root * $t) + [Math]::Sin(2 * [Math]::PI * $root * 1.26 * $t) + [Math]::Sin(2 * [Math]::PI * $root * 1.5 * $t))
      }
      $v = [int][Math]::Max(-32768, [Math]::Min(32767, $x))
      $out[2 * $i] = [byte]($v -band 0xFF); $out[2 * $i + 1] = [byte](($v -shr 8) -band 0xFF)
    }
    $w = New-Object System.IO.BinaryWriter([System.IO.File]::Create($path))
    $w.Write([Text.Encoding]::ASCII.GetBytes("RIFF")); $w.Write([int](36 + $out.Length)); $w.Write([Text.Encoding]::ASCII.GetBytes("WAVEfmt "))
    $w.Write([int]16); $w.Write([int16]1); $w.Write([int16]1); $w.Write([int]16000); $w.Write([int]32000); $w.Write([int16]2); $w.Write([int16]16)
    $w.Write([Text.Encoding]::ASCII.GetBytes("data")); $w.Write([int]$out.Length); $w.Write($out); $w.Close()
  }
  function Wakes([string]$path) {
    $lines = & $VenvPython $ListenPy $EngineFolder $Phrase $Sensitivity --wav $path 2>&1
    $err = $lines | Where-Object { "$_" -like "error|*" } | Select-Object -First 1
    if ($err) { throw "listen.py: $err" }
    return @($lines | Where-Object { "$_" -like "wake|*" }).Count
  }
  $checks = @(
    @($Phrase, $a, 0, $false, $true), @($Phrase, $b, 0, $false, $true), @($Phrase, $a, 3, $false, $true), @($Phrase, $b, -3, $false, $true),
    @($Phrase, $a, 0, $true, $true), @($Phrase, $b, 1, $true, $true),
    @("$Phrase, what's on my calendar today", $a, 0, $false, $true),
    @("Tyrone called about the permit yesterday", $a, 0, $false, $false), @("My brother Tyrone is coming over tonight", $b, 0, $false, $false),
    @("hey how are you", $b, 0, $false, $false), @("send the budget to finance", $a, 0, $true, $false),
    @("hey there Ron", $a, 0, $false, $false), @("hey Tony, grab the keys", $b, 0, $false, $false), @("high tone", $a, 0, $false, $false))
  $n = 0
  try {
    foreach ($t in $checks) {
      $path = Join-Path $folder ("clip_{0:00}.wav" -f $n++)
      Clip $t[0] $t[1] $t[2] $t[3] $path
      $woke = (Wakes $path) -gt 0
      "{0,-8} `"{1}`" ({2}, speed {3}{4}){5}" -f $(if ($woke) { "opens" } else { "ignored" }), $t[0], $t[1].Split(" ")[1], $t[2], $(if ($t[3]) { ", music" } else { "" }), $(if ($woke -ne $t[4]) { "   <-- WRONG" } else { "" })
      $ok = $ok -and ($woke -eq $t[4])
    }
  } catch { "voice checks: " + $_.Exception.Message + "   <-- WRONG"; $ok = $false }
  Remove-Item -Recurse -Force $folder
  $mic = Get-Microphone
  "microphone: " + $(if ($mic) { $mic.Name } else { "none on this PC" })
  $e = New-Object WakeListenerEngine.Ears
  $e.Start($VenvPython, "`"$ListenPy`" `"$EngineFolder`" `"$Phrase`" $Sensitivity")
  $until = (Get-Date).AddSeconds(15); $first = $null; $line = $null
  while ((Get-Date) -lt $until -and -not $first) { if ($e.Lines.TryDequeue([ref]$line) -and $line -notlike "level|*") { $first = $line } else { Start-Sleep -Milliseconds 100 } }
  $e.Stop()
  if ($first -like "ready|*") { "listening: opened " + $first.Substring(6) }
  else { "listening: " + $(if ($first) { $first } else { "no answer in 15 seconds" }) + $(if (-not $mic) { " (expected: no microphone here)" } else { "   <-- WRONG" }); if ($mic) { $ok = $false } }
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
$script:windowLoudest = 0
function Show-Meter {
  # While listening: what the engine itself receives. Otherwise Windows' own meter.
  $level = if ($script:ears) { $script:level } else { [WakeListenerAudio.DefaultMicrophone]::Level() }
  if ($level -gt $script:windowLoudest) { $script:windowLoudest = $level }
  $state = if ($level -lt 0) { "no microphone" } elseif (-not $script:ears) { "not listening" } elseif ($level -ge 15) { "hearing sound" } else { "quiet" }
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
$script:setupRequested = $false
$script:sensitivityChanged = $false
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Icon = [System.Drawing.SystemIcons]::Information
$script:tray.Visible = $true
$script:showItem = New-Object System.Windows.Forms.MenuItem("Show activity window")
$script:showItem.add_Click({ Set-WindowShown (-not $script:windowShown) })
$pauseItem = New-Object System.Windows.Forms.MenuItem("Pause listening")
$pauseItem.add_Click({ $script:paused = -not $script:paused; $this.Text = if ($script:paused) { "Resume listening" } else { "Pause listening" }; Say $(if ($script:paused) { "Paused: it won't open the assistant until you resume." } else { "Resumed." }); Set-TrayText })
# How easily it opens, remembered for next time.
$sensItem = New-Object System.Windows.Forms.MenuItem("Sensitivity")
foreach ($s in @(@("low", "Low: only when it's sure"), @("normal", "Normal"), @("high", "High: from farther away or with music"))) {
  $item = New-Object System.Windows.Forms.MenuItem($s[1])
  $item.Tag = $s[0]
  $item.RadioCheck = $true
  $item.Checked = ($s[0] -eq $Sensitivity)
  $item.add_Click({
    $script:Sensitivity = $this.Tag
    foreach ($i in $sensItem.MenuItems) { $i.Checked = ($i.Tag -eq $this.Tag) }
    try { $null = New-Item -ItemType Directory -Force $EngineFolder; Set-Content -Path $SettingsFile -Value ("sensitivity=" + $this.Tag) -Encoding ASCII } catch { }
    Say ("Sensitivity: " + $this.Tag + ".")
    $script:sensitivityChanged = $true
  })
  [void]$sensItem.MenuItems.Add($item)
}
$setupItem = New-Object System.Windows.Forms.MenuItem("Set up the engine again")
$setupItem.add_Click({ $script:setupRequested = $true; $script:setupForced = $true })
$openItem = New-Object System.Windows.Forms.MenuItem("Open the assistant now")
$openItem.add_Click({ try { Open-Assistant } catch { } })
$quitItem = New-Object System.Windows.Forms.MenuItem("Quit (stop listening)")
$quitItem.add_Click({ $script:quit = $true })
$script:tray.ContextMenu = New-Object System.Windows.Forms.ContextMenu(,[System.Windows.Forms.MenuItem[]]@($script:showItem, $pauseItem, $sensItem, $openItem, $setupItem, (New-Object System.Windows.Forms.MenuItem("-")), $quitItem))
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

# ---- Setting up the engine (first run, or after an update) ------------------
# A Python of our own (a virtual environment in $EngineFolder) with the engine's
# packages, and its model. Python itself comes from python.org through winget
# when the PC has none.
function Find-Python {
  foreach ($v in @("3.13", "3.12", "3.14", "3.11")) {
    try { $out = & py "-$v" -c "import sys; print(sys.executable)" 2>$null; if ($LASTEXITCODE -eq 0 -and $out) { return ($out | Select-Object -Last 1).Trim() } } catch { }
  }
  foreach ($c in @("python", "python3")) {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -notmatch "WindowsApps") {
      try { $ok = & $cmd.Source -c "import sys; print(sys.version_info >= (3, 11))" 2>$null; if ($ok -eq "True") { return $cmd.Source } } catch { }
    }
  }
  return $null
}
# Runs a program, keeping the tray responsive; its output lines go to $log. Returns its exit code.
function Invoke-Quietly([string]$file, [string]$arguments, [scriptblock]$log) {
  $e = New-Object WakeListenerEngine.Ears
  $e.Start($file, $arguments)
  $line = $null
  while ($e.Running -or $e.Lines.Count) {
    while ($e.Lines.TryDequeue([ref]$line)) { & $log $line }
    [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 150
  }
  return 0
}
function Test-Engine {
  if (-not (Test-Path $VenvPython)) { return $false }
  $marker = Join-Path $EngineFolder "packages.txt"
  if (-not (Test-Path $marker) -or (Get-Content $marker -Raw).Trim() -ne ($Packages -join " ")) { return $false }
  return (Test-Path (Join-Path $EngineFolder "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01\tokens.txt"))
}
function Install-Engine {
  $null = New-Item -ItemType Directory -Force $EngineFolder
  Set-WindowShown $true
  Say "Setting up the listening engine (once, a few minutes; it needs the internet)." White
  if (-not (Test-Path $VenvPython)) {
    $python = Find-Python
    if (-not $python) {
      Say "Installing Python 3.12 from python.org (for this Windows account only)..." Cyan
      $winget = Get-Command winget -ErrorAction SilentlyContinue
      if (-not $winget) { Say "Python isn't installed and winget isn't available. Install Python 3.12 from https://www.python.org/downloads/ (tick 'Add python.exe to PATH'), then start the wake listener again." Red; return $false }
      $p = Start-Process $winget.Source -ArgumentList "install -e --id Python.Python.3.12 --scope user --silent --accept-package-agreements --accept-source-agreements" -PassThru -WindowStyle Hidden
      while (-not $p.HasExited) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 300 }
      $python = Find-Python
      if (-not $python) { $python = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
      if (-not $python) { Say "Python didn't install. Install Python 3.12 from https://www.python.org/downloads/, then start the wake listener again." Red; return $false }
    }
    Say ("Using " + $python) DarkGray
    Say "Making the wake listener's own Python environment..." Cyan
    & $python -m venv (Join-Path $EngineFolder "py") 2>&1 | Out-Null
    if (-not (Test-Path $VenvPython)) { Say "Couldn't make the Python environment in $EngineFolder." Red; return $false }
  }
  Say "Installing the engine (sherpa-onnx and the microphone library)..." Cyan
  $null = Invoke-Quietly $VenvPython ("-m pip install --disable-pip-version-check --no-input -q " + ($Packages -join " ")) { param($l) if ($l -notmatch "notice") { Say $l DarkGray } }
  $check = & $VenvPython -c "import sherpa_onnx, sounddevice, numpy, sentencepiece; print('ok')" 2>$null
  if ($check -ne "ok") { Say "The engine didn't install. Check the internet connection, then choose 'Set up the engine again' from the tray icon." Red; return $false }
  Set-Content -Path (Join-Path $EngineFolder "packages.txt") -Value ($Packages -join " ") -Encoding ASCII
  $failed = $false
  $null = Invoke-Quietly $VenvPython ("`"$ListenPy`" --setup `"$EngineFolder`"") { param($l) $parts = $l.Split("|", 2); if ($parts[0] -eq "error") { $script:setupError = $parts[1]; Say ("Model: " + $parts[1]) Red } else { Say ("Model: " + $parts[-1]) DarkGray } }
  if (-not (Test-Engine)) { Say "The speech model didn't download. Check the internet connection, then choose 'Set up the engine again' from the tray icon." Red; return $false }
  Say "The engine is ready." Green
  return $true
}

# ---- Listening --------------------------------------------------------------
$script:ears = $null
$script:level = 0
function Start-Listening {
  Stop-Listening
  $e = New-Object WakeListenerEngine.Ears
  $wav = $env:WAKE_LISTENER_FAKE_MIC
  $e.Start($VenvPython, ("`"$ListenPy`" `"$EngineFolder`" `"$Phrase`" $Sensitivity" + $(if ($wav) { " --wav `"$wav`"" } else { "" })))
  $script:ears = $e
  $script:earsStarted = Get-Date
}
function Stop-Listening {
  $e = $script:ears; $script:ears = $null
  if ($e) { $e.Stop() }
}
function Why($err) { $e = $err.Exception; while ($e.InnerException) { $e = $e.InnerException }; return $e.Message }

# ---- Start ------------------------------------------------------------------
Clear-Host
Write-Host "Wake listener $Version" -ForegroundColor White
Write-Host "Say `"$Phrase`" and your assistant opens. A neural keyword engine listens, on this PC only."
Write-Host "Opens: $Url"
Write-Host "This window hides itself: the tray icon by the clock keeps listening, whatever window is in front."
Write-Host "Right-click the tray icon to show this window again, pause, change the sensitivity, or quit."
Write-Host "(If you click inside this window it pauses until you press Esc.)"
Write-Host ""
Set-TrayText
$needSetup = -not (Test-Engine)
if (-not $needSetup) {
  Say ("Sensitivity: " + $Sensitivity + ". Engine ready in " + $EngineFolder) DarkGray
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
$nextSetupTry = Get-Date
$lastLevelAt = Get-Date
# While the assistant is open it has the microphone: the listener lets go of it,
# and opens it afresh a couple of seconds after the assistant closes (a Bluetooth
# headset switches modes in between).
$handedOver = $false
$nextWindowCheck = Get-Date

while (-not $script:quit) {
  # Setting up the engine: on the first run, and when asked from the tray.
  if (($needSetup -and (Get-Date) -ge $nextSetupTry) -or $script:setupRequested) {
    $script:setupRequested = $false
    if (-not $handedOver) {
      Stop-Listening
      if ($script:setupForced) { Remove-Item (Join-Path $EngineFolder "packages.txt") -ErrorAction SilentlyContinue; $script:setupForced = $false }
      if (Install-Engine) { $needSetup = $false; Say "Listening for `"$Phrase`" now." White } else { $needSetup = $true; $nextSetupTry = (Get-Date).AddMinutes(2) }
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
  if ($handedOver -or $needSetup) {
    [System.Windows.Forms.Application]::DoEvents(); Show-Meter; Start-Sleep -Milliseconds 100
    continue
  }

  # A new sensitivity from the tray: listen again with it.
  if ($script:sensitivityChanged) { $script:sensitivityChanged = $false; $restartAt = Get-Date }

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
      if (-not $script:ears -or -not $mic -or $now.Id -ne $mic.Id -or $due) {
        if ($mic -and $now.Id -ne $mic.Id) { Say "The default microphone changed: listening on the new one." }
        $mic = $now; $restartAt = $null
        try {
          Start-Listening
          $lastLevelAt = Get-Date
          $since = Get-Date; $script:windowLoudest = 0; $quietWarned = $false
        } catch {
          Say ("Couldn't start listening: " + (Why $_) + " Trying again in a few seconds.") Red
          Stop-Listening
          $restartAt = (Get-Date).AddSeconds(5)
        }
      }
    }
  }

  # What the engine says.
  $line = $null
  while ($script:ears -and $script:ears.Lines.TryDequeue([ref]$line)) {
    $parts = $line.Split("|", 2)
    switch ($parts[0]) {
      "level" { $script:level = [int]$parts[1]; $lastLevelAt = Get-Date }
      "ready" {
        Say ("Listening on: " + $parts[1]) Green
        $script:micName = $parts[1]; Set-TrayText
        $host.UI.RawUI.WindowTitle = "Wake listener: listening on " + $parts[1]
        $script:lastStartError = $null
      }
      "stalled" { Say "The microphone stopped sending sound: opening it again." DarkYellow; Stop-Listening; $restartAt = Get-Date }
      "error" {
        if ($parts[1] -ne $script:lastStartError) { Say ("The listener stopped: " + $parts[1] + " Trying again in a few seconds.") Red }
        $script:lastStartError = $parts[1]
        Stop-Listening; $restartAt = (Get-Date).AddSeconds(5)
      }
      "stderr" { }
      "wake" {
        if (((Get-Date) - $last).TotalSeconds -lt $GraceSecs) { Say "Heard `"$Phrase`": it's opening now, ignored." DarkGray }
        elseif (Test-AssistantOpen) { Say "Heard `"$Phrase`": the assistant is already open, ignored." DarkGray }
        elseif ($script:paused) { Say "Heard `"$Phrase`": paused, so not opening." DarkGray }
        else {
          Say "Heard `"$Phrase`": opening the assistant." Cyan
          $script:lastHeard = (Get-Date -Format "HH:mm") + " opened"; Set-TrayText
          $last = Get-Date
          # Let go of the microphone first, so the assistant gets it cleanly.
          Stop-Listening
          $handedOver = $true
          Say "The assistant is open: not listening until it closes." DarkGray
          try { Open-Assistant } catch { Say ("Couldn't open the assistant: " + $_.Exception.Message) Red }
        }
      }
    }
    if ($handedOver) { break }
  }
  if ($handedOver) { continue }

  # The engine quit without saying why, or went quiet: start it again.
  if ($script:ears -and (-not $script:ears.Running) -and $script:ears.Lines.Count -eq 0) {
    if ($env:WAKE_LISTENER_FAKE_MIC) { $restartAt = Get-Date } else { Say "The listener stopped: starting it again." DarkYellow; $restartAt = (Get-Date).AddSeconds(2) }
    Stop-Listening
  } elseif ($script:ears -and ((Get-Date) - $lastLevelAt).TotalSeconds -gt 20 -and ((Get-Date) - $script:earsStarted).TotalSeconds -gt 20) {
    Say "The listener isn't answering: starting it again." DarkYellow
    Stop-Listening; $restartAt = Get-Date
  }

  # Silent too long: say so once (the meter should move when you talk).
  if ($script:ears -and ((Get-Date) - $since).TotalSeconds -ge 20) {
    if ($script:windowLoudest -lt 3 -and -not $quietWarned -and $script:micName) { Say ("No sound at all from " + $script:micName + " for 20 seconds: check its mute button and its input volume (Settings > System > Sound > Input).") Yellow; $quietWarned = $true }
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
