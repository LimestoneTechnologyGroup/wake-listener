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

$Version = "6.3.1"

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
# Choices made from the tray menu (sensitivity, the floating button), kept as name=value lines.
function Get-Setting([string]$name) {
  try { $line = Get-Content $SettingsFile -ErrorAction Stop | Where-Object { $_ -like "$name=*" } | Select-Object -Last 1; if ($line) { return $line.Substring($name.Length + 1) } } catch { }
  return $null
}
function Set-Setting([string]$name, [string]$value) {
  try {
    $null = New-Item -ItemType Directory -Force $EngineFolder
    $lines = @(try { Get-Content $SettingsFile -ErrorAction Stop | Where-Object { $_ -notlike "$name=*" } } catch { })
    Set-Content -Path $SettingsFile -Value ($lines + "$name=$value") -Encoding ASCII
  } catch { }
}
$saved = Get-Setting "sensitivity"; if ($saved -in @("low", "normal", "high")) { $Sensitivity = $saved }

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
  $script:openedAt = Get-Date; $script:keepShown = $false
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
$script:sayColors = @{ Green = @(74, 222, 128); Cyan = @(103, 232, 249); Yellow = @(250, 204, 21); Red = @(248, 113, 113); DarkGray = @(148, 163, 184); DarkYellow = @(234, 179, 8); White = @(255, 255, 255); Gray = @(226, 232, 240) }
function Say([string]$text, [string]$color = "Gray") {
  Clear-Meter
  $line = "{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $text
  Write-Host $line -ForegroundColor $color
  if ($script:activity) { $c = $script:sayColors[$color]; if (-not $c) { $c = $script:sayColors.Gray }; $script:activity.Add($line, [System.Drawing.Color]::FromArgb($c[0], $c[1], $c[2])) }
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
  if ($script:activity -and $script:activity.Visible) { $script:activity.Meter($line.Trim()) }
  if (Get-Command Step-Pill -ErrorAction SilentlyContinue) { Step-Pill }
}

# ---- The tray icon ----------------------------------------------------------
# It lives next to the clock and keeps listening whatever window is in front.
# The activity window (meter and log) starts hidden; the tray menu shows it.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace WakeListenerDpi -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
[void][WakeListenerDpi.Native]::SetProcessDPIAware()
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
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr window, int show);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
    /// <summary>Brings the browser window whose title contains titlePart to the front (restoring it if minimized).</summary>
    public static bool Focus(string titlePart) {
      IntPtr hit = IntPtr.Zero;
      EnumWindows((w, p) => {
        var text = new StringBuilder(512);
        GetWindowText(w, text, text.Capacity);
        if (text.ToString().IndexOf(titlePart, StringComparison.OrdinalIgnoreCase) < 0) return true;
        uint pid; GetWindowThreadProcessId(w, out pid);
        try { var name = Process.GetProcessById((int)pid).ProcessName.ToLowerInvariant(); if (name == "msedge" || name == "chrome") { hit = w; return false; } } catch { }
        return true;
      }, IntPtr.Zero);
      if (hit == IntPtr.Zero) return false;
      if (IsIconic(hit)) ShowWindow(hit, 9);
      return SetForegroundWindow(hit);
    }
    /// <summary>The assistant's browser window (visible or hidden), or zero.</summary>
    public static IntPtr Find(string titlePart) {
      IntPtr hit = IntPtr.Zero;
      EnumWindows((w, p) => {
        var text = new StringBuilder(512);
        GetWindowText(w, text, text.Capacity);
        if (text.ToString().IndexOf(titlePart, StringComparison.OrdinalIgnoreCase) < 0) return true;
        uint pid; GetWindowThreadProcessId(w, out pid);
        try { var name = Process.GetProcessById((int)pid).ProcessName.ToLowerInvariant(); if (name == "msedge" || name == "chrome") { hit = w; return false; } } catch { }
        return true;
      }, IntPtr.Zero);
      return hit;
    }
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr window);
    /// <summary>The window still exists and still has the title (the page closes it when the conversation is saved).</summary>
    public static bool Alive(IntPtr w, string titlePart) {
      if (w == IntPtr.Zero || !IsWindow(w)) return false;
      var text = new StringBuilder(512); GetWindowText(w, text, text.Capacity);
      return text.ToString().IndexOf(titlePart, StringComparison.OrdinalIgnoreCase) >= 0;
    }
    public static bool Visible(IntPtr w) { return w != IntPtr.Zero && IsWindowVisible(w); }
    public static void Hide(IntPtr w) { if (w != IntPtr.Zero) ShowWindow(w, 0); }
    public static bool Reveal(IntPtr w) { if (w == IntPtr.Zero) return false; ShowWindow(w, IsIconic(w) ? 9 : 5); return SetForegroundWindow(w); }
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
# Open: a visible assistant window, or the one we hid (it's still there, talking).
$script:assistantWindow = [IntPtr]::Zero
function Test-AssistantOpen {
  try {
    if ([WakeListenerWindows.Browser]::Alive($script:assistantWindow, $AssistantTitle)) { return $true }
    $script:assistantWindow = [IntPtr]::Zero
    return [WakeListenerWindows.Browser]::HasWindow($AssistantTitle)
  } catch { $false }
}
# Shows Tyrone's window (it may be hidden); false when there's none.
function Show-Assistant {
  $w = if ([WakeListenerWindows.Browser]::Alive($script:assistantWindow, $AssistantTitle)) { $script:assistantWindow } else { [WakeListenerWindows.Browser]::Find($AssistantTitle) }
  return [WakeListenerWindows.Browser]::Reveal($w)
}

$script:consoleWindow = [WakeListenerWindow.Native]::GetConsoleWindow()
if (-not $Test) { [void][WakeListenerWindow.Native]::ShowWindow($script:consoleWindow, 0) }
$script:windowShown = $false
function Set-WindowShown([bool]$show) {
  if (-not $script:activity) { return }
  if ($show) { $script:activity.Bring() } else { $script:activity.Hide() }
}
$script:paused = $false
$script:quit = $false
$script:setupRequested = $false
$script:sensitivityChanged = $false
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Icon = [System.Drawing.SystemIcons]::Information
$script:tray.Visible = $true
$script:showItem = New-Object System.Windows.Forms.MenuItem("Show activity window")
$script:showItem.add_Click({ Set-WindowShown $true })
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
    Set-Setting "sensitivity" $this.Tag
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
  $text = $(if ($script:paused) { "Wake listener $Version`: paused" } else { "Wake listener $Version`: listening" }) + "`n" + $micName + $(if ($script:lastHeard) { "`nLast: " + $script:lastHeard } else { "" })
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

Add-Type -Path (Join-Path $PSScriptRoot "WakeUi.cs") -ReferencedAssemblies System.Windows.Forms, System.Drawing

# The activity window: what the listener is doing. Hidden until you double-click
# the floating button (or choose it from the menu); closing it only hides it.
$script:activity = New-Object WakeUi.Activity("Wake listener " + $Version)

# ---- The floating button ----------------------------------------------------
# Floating Tyrone (WakeUi.cs): always on top. It shows whether Tyrone is
# listening, and Start or Stop: Start opens the assistant, Stop ends the
# conversation the way End discussion does (so it's saved). Click it to bring
# the assistant to the front; double-click it for the activity window; drag it
# anywhere (it's remembered); right-click for the menu. Under it, what you
# chose from "Show on the button": to-dos due today, Kitchen orders, the next
# meeting, the last talk with Tyrone (read from Project Check-in with your key).
$GlanceUrl = ($Url -replace "/assistant.*$", "") + "/api/teams/messages/intake/summary"
$script:pillColors = @{
  listening = [System.Drawing.Color]::FromArgb(74, 222, 128); open = [System.Drawing.Color]::FromArgb(96, 165, 250)
  paused = [System.Drawing.Color]::FromArgb(148, 163, 184); setup = [System.Drawing.Color]::FromArgb(251, 191, 36)
  problem = [System.Drawing.Color]::FromArgb(248, 113, 113)
}
$pill = New-Object WakeUi.Pill
$pill.Display("Starting", $script:pillColors.setup, "", "", -1)
$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$at = New-Object System.Drawing.Point(($area.Right - $pill.Width - 24), ($area.Bottom - $pill.Height - 24))
$placed = Get-Setting "button"
if ($placed -match "^(-?\d+),(-?\d+)$") {
  $p = New-Object System.Drawing.Point([int]$Matches[1], [int]$Matches[2])
  if ([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.Contains($p) }) { $at = $p }
}
$pill.Location = $at

# What to show under it, and the key it reads your day with.
$script:showChoices = @(@("due", "To-dos due today"), @("kitchen", "Kitchen orders"), @("next", "Next meeting"), @("last", "Last talk with Tyrone"))
function Get-Shown { $v = Get-Setting "show"; if ($null -eq $v) { return @("due", "next") } else { return @($v.Split(",") | Where-Object { $_ }) } }
$showItem2 = New-Object System.Windows.Forms.MenuItem("Show on the button")
foreach ($c in $script:showChoices) {
  $item = New-Object System.Windows.Forms.MenuItem($c[1]); $item.Tag = $c[0]; $item.Checked = ((Get-Shown) -contains $c[0])
  $item.add_Click({
    $this.Checked = -not $this.Checked
    Set-Setting "show" ((@($showItem2.MenuItems | Where-Object { $_.Checked -and $_.Tag } | ForEach-Object { $_.Tag })) -join ",")
    $script:glanceAt = [datetime]::MinValue
  })
  [void]$showItem2.MenuItems.Add($item)
}
[void]$showItem2.MenuItems.Add("-")
$connectItem = New-Object System.Windows.Forms.MenuItem("Connect to Project Check-in...")
$connectItem.add_Click({ $script:connectRequested = $true })
[void]$showItem2.MenuItems.Add($connectItem)
$pasteItem = New-Object System.Windows.Forms.MenuItem("Paste a key instead...")
$pasteItem.add_Click({ $script:pasteRequested = $true })
[void]$showItem2.MenuItems.Add($pasteItem)
function Get-Key {
  $sealed = Get-Setting "key"
  if (-not $sealed) { return $null }
  try { $s = ConvertTo-SecureString $sealed; return [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)) } catch { return $null }
}
# Connect: opens Project Check-in's one-click page; it posts a fresh key back to
# this PC (http://localhost:<port>/connect) with the one-time state we sent.
$script:linkServer = $null; $script:linkTask = $null; $script:linkState = $null; $script:linkUntil = [datetime]::MinValue
function Connect-App {
  Stop-LinkServer
  $rnd = New-Object System.Random
  $script:linkState = -join (1..32 | ForEach-Object { "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"[$rnd.Next(62)] })
  foreach ($try in 1..10) {
    $port = $rnd.Next(49200, 64000)
    $server = New-Object System.Net.HttpListener
    $server.Prefixes.Add("http://localhost:$port/")
    try { $server.Start(); $script:linkServer = $server; break } catch { $server.Close() }
  }
  if (-not $script:linkServer) { Say "Couldn't open a local port to receive the key: use Paste a key instead from the menu." Yellow; return }
  $script:linkTask = $script:linkServer.GetContextAsync()
  $script:linkUntil = (Get-Date).AddMinutes(5)
  $page = ($Url -replace "/assistant.*$", "") + "/settings/datalink/listener?port=$port&state=" + $script:linkState
  Say "Connecting to Project Check-in: press Connect on the page that opened (it waits five minutes)." Cyan
  $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($Browser -eq "edge-app" -and $edge) { Start-Process $edge "--app=$page" } else { Start-Process $page }
}
function Stop-LinkServer {
  if ($script:linkServer) { try { $script:linkServer.Stop(); $script:linkServer.Close() } catch { } }
  $script:linkServer = $null; $script:linkTask = $null
}
# Waits for the page's post without holding anything up.
function Step-Link {
  if (-not $script:linkServer) { return }
  # Connected: the page's answer goes out first, then the port closes.
  if ($script:linkDone) { if (((Get-Date) - $script:linkDone).TotalSeconds -ge 2) { $script:linkDone = $null; Stop-LinkServer }; return }
  if ((Get-Date) -gt $script:linkUntil) { Stop-LinkServer; Say "Connecting timed out: choose Connect to Project Check-in again." DarkYellow; return }
  $t = $script:linkTask
  if (-not $t -or -not $t.IsCompleted) { return }
  $ctx = $null
  try { $ctx = $t.Result } catch { Stop-LinkServer; return }
  $ok = $false
  try {
    if ($ctx.Request.HttpMethod -eq "POST" -and $ctx.Request.Url.AbsolutePath -eq "/connect") {
      $body = (New-Object System.IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
      $form = @{}
      foreach ($pair in $body.Split("&")) { $kv = $pair.Split("=", 2); if ($kv.Count -eq 2) { $form[[Uri]::UnescapeDataString($kv[0].Replace("+", " "))] = [Uri]::UnescapeDataString($kv[1].Replace("+", " ")) } }
      if ($form["state"] -eq $script:linkState -and $form["key"] -match "^pci_[A-Za-z0-9_-]{20,100}$") {
        Set-Setting "key" (ConvertFrom-SecureString (ConvertTo-SecureString $form["key"] -AsPlainText -Force))
        $ok = $true
      }
    }
    $html = if ($ok) { "<!doctype html><meta charset=utf-8><title>Connected</title><body style='font-family:Segoe UI,sans-serif;padding:40px;background:#0c1e36;color:#fff'><h1>Connected</h1><p>Floating Tyrone will show your day in a moment. You can close this window.</p><script>setTimeout(function(){window.close()},2500)</script>" } else { "<!doctype html><meta charset=utf-8><title>Not connected</title><body style='font-family:Segoe UI,sans-serif;padding:40px'><h1>Not connected</h1><p>That didn't come from this connect. Choose Connect to Project Check-in from the wake listener's menu again.</p>" }
    $bytes = [Text.Encoding]::UTF8.GetBytes($html)
    $ctx.Response.ContentType = "text/html; charset=utf-8"; $ctx.Response.StatusCode = $(if ($ok) { 200 } else { 400 })
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length); $ctx.Response.Close()
  } catch { }
  if ($ok) {
    $script:linkDone = Get-Date
    $script:glanceAt = [datetime]::MinValue
    Say "Connected to Project Check-in: Floating Tyrone shows your day." Green
  } else { $script:linkTask = $script:linkServer.GetContextAsync() }
}
# The fallback: paste a key made on the Datalink page.
function Paste-Key {
  Add-Type -AssemblyName Microsoft.VisualBasic
  $key = [Microsoft.VisualBasic.Interaction]::InputBox("Paste a key from Project Check-in: Settings > Datalink > Make a key (name it Wake listener). It's kept encrypted for your Windows account only.", "Connect to Project Check-in", "")
  if (-not $key) { return }
  $key = $key.Trim()
  if ($key -notmatch "^pci_[A-Za-z0-9_-]{20,100}$") { [void][System.Windows.Forms.MessageBox]::Show("That isn't a Project Check-in key: they start with pci_. Make one under Settings > Datalink.", "Connect to Project Check-in"); return }
  Set-Setting "key" (ConvertFrom-SecureString (ConvertTo-SecureString $key -AsPlainText -Force))
  $script:glanceAt = [datetime]::MinValue
  Say "Connected to Project Check-in: the button shows your day." Green
}

# Your day, read every two minutes in the background (the page never waits on it).
$script:glance = $null; $script:glanceAt = [datetime]::MinValue; $script:glanceTask = $null; $script:glanceProblem = ""
function Step-Glance {
  $shown = Get-Shown
  if (-not $shown.Count) { $script:glance = $null; return }
  $t = $script:glanceTask
  if ($t -and $t.IsCompleted) {
    $script:glanceTask = $null
    if ($t.Status -eq "RanToCompletion") { try { $script:glance = $t.Result | ConvertFrom-Json; $script:glanceProblem = "" } catch { $script:glanceProblem = "couldn't read your day" } }
    else {
      $why = $t.Exception.InnerException
      $script:glanceProblem = if ("$why" -match "401") { "the key was refused: connect again" } else { "Project Check-in didn't answer" }
    }
    $t.Dispose()
  }
  if ($script:glanceTask -or ((Get-Date) - $script:glanceAt).TotalSeconds -lt 120) { return }
  $key = Get-Key
  if (-not $key) { $script:glanceProblem = "Click here to show your day"; return }
  $script:glanceAt = Get-Date
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $web = New-Object System.Net.WebClient
  $web.Headers["Authorization"] = "Bearer $key"; $web.Headers["User-Agent"] = "WakeListener"; $web.Encoding = [Text.Encoding]::UTF8
  $script:glanceTask = $web.DownloadStringTaskAsync($GlanceUrl)
}
function Get-GlanceLine {
  $shown = Get-Shown
  if (-not $shown.Count) { return "" }
  if (-not $script:glance) { return $script:glanceProblem }
  $g = $script:glance; $parts = @()
  if ($shown -contains "due") { $parts += $(if ($g.dueToday) { "$($g.dueToday) due today" + $(if ($g.overdue) { " ($($g.overdue) late)" } else { "" }) } else { "Nothing due today" }) }
  if ($shown -contains "kitchen") { $parts += "Kitchen $($g.kitchen)" }
  if ($shown -contains "next") { if ($g.nextMeeting) { $parts += ("Next: " + $g.nextMeeting.subject + " " + ([datetime]$g.nextMeeting.start).ToString("h:mm tt")) } }
  if ($shown -contains "last") { if ($g.lastTalk) { $parts += ("Last talk " + ([datetime]$g.lastTalk.at).ToString("ddd h:mm tt")) } }
  return ($parts -join " · ")
}

# Puts the current state on the button.
function Update-Pill {
  $state, $word = if ($script:setupNeeded) { "setup", "Setting up" }
    elseif ($script:assistantOpen) { "open", "Talking" }
    elseif ($script:paused) { "paused", "Paused" }
    elseif (-not $script:micName) { "problem", "No microphone" }
    elseif (-not $script:ears) { "setup", "Starting" }
    else { "listening", "Listening" }
  $action = if ($script:setupNeeded) { "" } elseif ($script:assistantOpen) { "Stop" } else { "Start" }
  $lvl = if ($state -eq "listening") { [int]([Math]::Round([Math]::Min(100, [Math]::Max(0, $script:level)) / 10) * 10) } else { -1 }
  if ($pill.Visible) { $pill.Display($word, $script:pillColors[$state], (Get-GlanceLine), $action, $lvl) }
}
# What was done with it.
function Step-Pill {
  Step-Glance
  $click = $null
  while ($pill.Clicks.TryDequeue([ref]$click)) {
    switch -Wildcard ($click) {
      "start" { $script:openRequested = $true }
      "stop" { $script:stopRequested = $true }
      "front" {
        if (Test-AssistantOpen) {
          $w = [WakeListenerWindows.Browser]::Find($AssistantTitle)
          if ([WakeListenerWindows.Browser]::Visible($w)) { $script:assistantWindow = $w; [WakeListenerWindows.Browser]::Hide($w); $script:keepShown = $false }
          else { [void](Show-Assistant); $script:keepShown = $true }
        } elseif (-not (Get-Key)) { $script:connectRequested = $true }
      }
      "activity" { Set-WindowShown $true }
      "menu" { $script:tray.ContextMenu.Show($pill, $pill.PointToClient([System.Windows.Forms.Cursor]::Position)) }
      "moved|*" { Set-Setting "button" $click.Substring(6) }
    }
  }
  if ($script:connectRequested) { $script:connectRequested = $false; Connect-App }
  if ($script:pasteRequested) { $script:pasteRequested = $false; Paste-Key }
  Step-Link
  Step-Hide
  Update-Pill
}
# Tyrone's window hides itself a few seconds after it opens (once the voice has
# started), so only Floating Tyrone shows; he keeps talking. Click the button to
# show it again. "Show Tyrone's window" on the menu turns the hiding off.
$script:openedAt = $null; $script:keepShown = $false
function Step-Hide {
  if (-not $script:openedAt) { return }
  if ((Get-Setting "hide-window") -eq "no" -or $script:keepShown) { $script:openedAt = $null; return }
  if (((Get-Date) - $script:openedAt).TotalSeconds -lt 6) { return }
  $w = [WakeListenerWindows.Browser]::Find($AssistantTitle)
  if ($w -ne [IntPtr]::Zero) {
    $script:assistantWindow = $w
    [WakeListenerWindows.Browser]::Hide($w)
    $script:openedAt = $null
    Say "Tyrone's window is hidden while he talks: click Floating Tyrone to show it." DarkGray
  } elseif (((Get-Date) - $script:openedAt).TotalSeconds -gt 60) { $script:openedAt = $null }
}
$hideItem = New-Object System.Windows.Forms.MenuItem("Hide Tyrone's window while he talks")
$hideItem.Checked = ((Get-Setting "hide-window") -ne "no")
$hideItem.add_Click({ $this.Checked = -not $this.Checked; Set-Setting "hide-window" $(if ($this.Checked) { "yes" } else { "no" }) })

# Stop: the assistant's page ends the conversation on Escape, exactly as End discussion does.
function Stop-Assistant {
  if (-not (Test-AssistantOpen)) { return }
  if (Show-Assistant) {
    Start-Sleep -Milliseconds 250
    [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
    Say "Ending the conversation (the floating button)." Cyan
  } else { Say "Couldn't reach the assistant's window to end the conversation: use End discussion there." Yellow }
}
function Set-PillShown([bool]$show) {
  $script:pillItem.Text = if ($show) { "Hide floating button" } else { "Show floating button" }
  Set-Setting "button-shown" $(if ($show) { "yes" } else { "no" })
  if ($show) { $pill.Show(); Update-Pill } else { $pill.Hide() }
}
$script:pillItem = New-Object System.Windows.Forms.MenuItem("Hide floating button")
$script:pillItem.add_Click({ Set-PillShown (-not $pill.Visible) })
$script:tray.ContextMenu.MenuItems.Add(1, $script:pillItem) | Out-Null
$script:tray.ContextMenu.MenuItems.Add(3, $showItem2) | Out-Null
$script:tray.ContextMenu.MenuItems.Add(4, $hideItem) | Out-Null
if ((Get-Setting "button-shown") -ne "no") { $pill.Show() } else { $script:pillItem.Text = "Show floating button" }

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
  $e.Start($VenvPython, ("`"$ListenPy`" `"$EngineFolder`" `"$Phrase`" $Sensitivity" + $(if ($wav) { " --wav `"$wav`" --realtime" } else { "" })))
  $script:ears = $e
  $script:earsStarted = Get-Date
}
function Stop-Listening {
  $e = $script:ears; $script:ears = $null
  if ($e) { $e.Stop() }
}
function Why($err) { $e = $err.Exception; while ($e.InnerException) { $e = $e.InnerException }; return $e.Message }

# ---- Updating itself --------------------------------------------------------
# On start and once a day, it asks GitHub for the latest release. A newer one is
# downloaded, its checksum checked when GitHub gives one, its script checked to
# be readable, then copied over these files, and the listener starts again.
# Never while the assistant is open.
$UpdateApi = "https://api.github.com/repos/LimestoneTechnologyGroup/wake-listener/releases/latest"
function Find-Update {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $r = Invoke-RestMethod -Uri $UpdateApi -Headers @{ "User-Agent" = "WakeListener"; "Accept" = "application/vnd.github+json" } -TimeoutSec 20
  $latest = [version]($r.tag_name -replace "^v", "")
  if ($latest -le [version]$Version) { return $null }
  $asset = $r.assets | Where-Object { $_.name -eq "WakeListener.zip" } | Select-Object -First 1
  if (-not $asset) { return $null }
  return [pscustomobject]@{ Version = $latest; Url = $asset.browser_download_url; Digest = $asset.digest; Notes = $r.name }
}
function Install-Update($u, [string]$into) {
  if (-not $into -or -not (Test-Path (Join-Path $into "WakeListener.ps1"))) { throw "the wake listener's folder wasn't found" }
  $work = Join-Path ([IO.Path]::GetTempPath()) ("wake-listener-update-" + [guid]::NewGuid())
  $null = New-Item -ItemType Directory $work
  try {
    $zip = Join-Path $work "WakeListener.zip"
    Invoke-WebRequest -Uri $u.Url -OutFile $zip -UseBasicParsing -TimeoutSec 120 -Headers @{ "User-Agent" = "WakeListener" }
    if ($u.Digest -match "^sha256:([0-9a-f]{64})$") {
      if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Matches[1]) { throw "the download didn't match its checksum" }
    }
    Expand-Archive -Path $zip -DestinationPath (Join-Path $work "x") -Force
    $script = Join-Path $work "x\WakeListener.ps1"
    if (-not (Test-Path $script)) { throw "the download has no WakeListener.ps1" }
    $errs = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$errs)
    if ($errs) { throw "the new script didn't read cleanly" }
    Get-ChildItem (Join-Path $work "x") -File | Copy-Item -Destination $into -Force
    return $true
  } finally { Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue }
}
function Restart-Listener {
  $cmd = Join-Path $PSScriptRoot "Start wake listener.cmd"
  if (Test-Path $cmd) { Start-Process -FilePath $cmd -WorkingDirectory $PSScriptRoot -WindowStyle Minimized }
  else { Start-Process powershell.exe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"") -WindowStyle Minimized }
  $script:quit = $true
}
$script:nextUpdateCheck = (Get-Date).AddSeconds(30)
$script:updateNow = $false
function Step-Update([bool]$asked) {
  $script:nextUpdateCheck = (Get-Date).AddHours(24)
  if ($env:WAKE_LISTENER_FAKE_MIC -or ((Get-Setting "auto-update") -eq "no" -and -not $asked)) { return }
  try { $u = Find-Update } catch { if ($asked) { Say ("Couldn't check for updates: " + (Why $_)) Yellow }; return }
  if (-not $u) { if ($asked) { Say "You have the latest version ($Version)." Green }; return }
  Say ("Updating to " + $u.Version + "...") Cyan
  try {
    if (Install-Update $u $PSScriptRoot) {
      Say ("Updated to " + $u.Version + ": starting it again.") Green
      $script:tray.ShowBalloonTip(5000, "Wake listener updated", ("Now on " + $u.Version + ". It's starting again."), [System.Windows.Forms.ToolTipIcon]::Info)
      Restart-Listener
    }
  } catch { Say ("The update to " + $u.Version + " didn't install: " + (Why $_) + " It'll try again tomorrow, or choose 'Check for updates' from the tray icon.") Yellow }
}
$updateItem = New-Object System.Windows.Forms.MenuItem("Check for updates")
$updateItem.add_Click({ $script:updateNow = $true })
$script:tray.ContextMenu.MenuItems.Add($script:tray.ContextMenu.MenuItems.Count - 2, $updateItem) | Out-Null

# The version, at the top of the menu (the tray icon's and Floating Tyrone's).
$versionItem = New-Object System.Windows.Forms.MenuItem("Wake listener $Version")
$versionItem.Enabled = $false
$script:tray.ContextMenu.MenuItems.Add(0, $versionItem) | Out-Null
$script:tray.ContextMenu.MenuItems.Add(1, (New-Object System.Windows.Forms.MenuItem("-"))) | Out-Null

# ---- Start ------------------------------------------------------------------
Clear-Host
Write-Host "Wake listener $Version" -ForegroundColor White
Write-Host "Say `"$Phrase`" and your assistant opens. A neural keyword engine listens, on this PC only."
Write-Host "Opens: $Url"
Say "Floating Tyrone shows whether he's listening. Start opens him, Stop ends the conversation; double-click it for this window, drag it anywhere, right-click for options." White
Say "Closing this window only hides it: the listener keeps running. Quit from the menu." White
Write-Host ""
Set-TrayText
$needSetup = -not (Test-Engine)
if (-not $needSetup) {
  Say ("Sensitivity: " + $Sensitivity + ". Engine ready in " + $EngineFolder) DarkGray
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
  $script:setupNeeded = $needSetup; $script:assistantOpen = $handedOver
  if ($script:stopRequested) { $script:stopRequested = $false; Stop-Assistant }
  # The floating button was clicked: open the assistant now.
  if ($script:openRequested) {
    $script:openRequested = $false
    if (-not $handedOver -and -not $needSetup) {
      Say "Opening the assistant (the floating button)." Cyan
      $script:lastHeard = (Get-Date -Format "HH:mm") + " opened"; Set-TrayText
      $last = Get-Date
      Stop-Listening
      $handedOver = $true; $script:assistantOpen = $true
      try { Open-Assistant } catch { Say ("Couldn't open the assistant: " + $_.Exception.Message) Red }
      continue
    } elseif (-not $needSetup) { try { Open-Assistant } catch { } }
  }
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

  # A newer version: on start, once a day, or when asked from the tray.
  if ($script:updateNow -or (Get-Date) -ge $script:nextUpdateCheck) {
    $asked = $script:updateNow; $script:updateNow = $false
    Step-Update $asked
    if ($script:quit) { break }
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
Stop-LinkServer
$pill.Close(); $script:activity.Dispose()
$script:tray.Visible = $false
$script:tray.Dispose()
