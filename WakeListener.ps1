# Wake listener: say "hey assistant" and your Project Check-in assistant opens.
#
# Plain PowerShell, no exe. It uses Windows 10/11's built-in speech recognizer
# (the newer one, Windows.Media.SpeechRecognition), listening only for a short
# list of phrases, on this PC: nothing is recorded or sent anywhere. When it
# hears the phrase, it opens the assistant's voice page, which starts talking.
#
# The window shows what's going on: which microphone, a live level meter
# (Windows' own meter for that microphone), and everything it hears and why it
# did or didn't open. It follows you if you change your default microphone.
#
# Run it: double-click "Start wake listener.cmd" (or right-click this file >
# Run with PowerShell). Close the window to stop.
# Check it without a microphone: WakeListener.ps1 -Test

param([switch]$Test)

$Version = "3.0.0"

# ---- Settings ---------------------------------------------------------------
$Phrases       = @("hey assistant", "okay assistant", "hi assistant", "ok assistant")   # what to say, lowercase
$Url           = "https://project-checkin.dev.limestonetg.com/assistant?start=voice"
$Browser       = "edge-app"   # edge-app, chrome-app, or default
$MinConfidence = 0.5          # 0 to 1: raise it if it opens by mistake; lower it if it misses you
$CooldownSecs  = 45           # ignore the phrase this long after opening
# -----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$null = [Windows.Media.SpeechRecognition.SpeechRecognizer, Windows.Media.SpeechRecognition, ContentType = WindowsRuntime]

# Windows' async calls, waited for from PowerShell. While waiting, $During runs every 120 ms (the level meter).
$asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq "AsTask" -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
function Wait-Windows($operation, [Type]$type, [scriptblock]$During) {
  $task = $asTask.MakeGenericMethod($type).Invoke($null, @($operation))
  while (-not $task.Wait(120)) { if ($During) { & $During } }
  return $task.Result
}

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
  $d = [WakeListenerAudio.DefaultMicrophone]::Describe()
  if (-not $d) { return $null }
  $i = $d.IndexOf("|")
  return [pscustomobject]@{ Id = $d.Substring(0, $i); Name = $d.Substring($i + 1) }
}

# A recognizer that listens only for the phrases. Returns it, or throws why not.
function New-Recognizer {
  $r = New-Object Windows.Media.SpeechRecognition.SpeechRecognizer
  $list = New-Object Windows.Media.SpeechRecognition.SpeechRecognitionListConstraint(([string[]]$Phrases), "wake")
  # PowerShell can't call Add on this Windows collection directly; call it through .NET's interface.
  $null = [System.Collections.Generic.ICollection[Windows.Media.SpeechRecognition.ISpeechRecognitionConstraint]].GetMethod("Add").Invoke($r.Constraints.psobject.BaseObject, [object[]]@($list.psobject.BaseObject))
  $compiled = Wait-Windows ($r.CompileConstraintsAsync()) ([Windows.Media.SpeechRecognition.SpeechRecognitionCompilationResult])
  if ($compiled.Status -ne "Success") { throw "Windows couldn't set up the phrases ($($compiled.Status))." }
  $r.Timeouts.InitialSilenceTimeout = [TimeSpan]::FromSeconds(20)
  $r.Timeouts.BabbleTimeout = [TimeSpan]::FromSeconds(4)
  $r.Timeouts.EndSilenceTimeout = [TimeSpan]::FromMilliseconds(300)
  return $r
}

if ($Test) {
  $ok = $true
  "speech language: " + [Windows.Media.SpeechRecognition.SpeechRecognizer]::SystemSpeechLanguage.LanguageTag
  try { $r = New-Recognizer; "phrases: ready (" + ($Phrases -join ", ") + ")" } catch { "phrases: FAILED " + $_.Exception.Message; $ok = $false }
  $mic = Get-Microphone
  "microphone: " + $(if ($mic) { $mic.Name + ", level " + [WakeListenerAudio.DefaultMicrophone]::Level() } else { "none on this PC" })
  if ($r) {
    $r.Timeouts.InitialSilenceTimeout = [TimeSpan]::FromSeconds(3)
    try { $res = Wait-Windows ($r.RecognizeAsync()) ([Windows.Media.SpeechRecognition.SpeechRecognitionResult]); "listen once: " + $res.Status } catch { "listen once: FAILED " + $_.Exception.Message; $ok = $false }
  }
  if ($ok) { exit 0 } else { exit 1 }
}

function Open-Assistant {
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
function Say([string]$text, [string]$color = "Gray") { Clear-Meter; Write-Host ("{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $text) -ForegroundColor $color }
$script:loudest = 0
function Show-Meter {
  $level = [WakeListenerAudio.DefaultMicrophone]::Level()
  if ($level -gt $script:loudest) { $script:loudest = $level }
  $state = if ($level -lt 0) { "no microphone" } elseif ($level -ge 8) { "hearing sound" } else { "quiet" }
  $shown = [Math]::Max(0, $level)
  $bars = [Math]::Round($shown / 100 * 30)
  $line = "  Mic level [" + ("#" * $bars).PadRight(30, ".") + "] " + ("{0,3}" -f $shown) + "   " + $state
  [Console]::Write("`r" + $line.PadRight((Width)).Substring(0, (Width)))
  $script:meterShown = $true
}

Clear-Host
Write-Host "Wake listener $Version (Windows speech recognizer)" -ForegroundColor White
Write-Host ("Say " + (($Phrases | Select-Object -First 2 | ForEach-Object { "`"$_`"" }) -join " or ") + " and your assistant opens (when it's at least {0:0}% sure)." -f ($MinConfidence * 100))
Write-Host "Opens: $Url"
Write-Host "Don't click inside this window: a click pauses it until you press Esc. Close it to stop."
Write-Host ""

$recognizer = $null
$mic = $null
$last = [datetime]::MinValue
$since = Get-Date
$quietWarned = $false

while ($true) {
  # Follow the default microphone: (re)start on it whenever it changes.
  $now = Get-Microphone
  if (-not $now) {
    if ($mic -or -not $recognizer -and -not $script:noMicSaid) { Say "No microphone found. Plug one in or set a default in Settings > System > Sound > Input. Checking every few seconds." Yellow; $script:noMicSaid = $true }
    $mic = $null; $recognizer = $null
    1..25 | ForEach-Object { Show-Meter; Start-Sleep -Milliseconds 120 }
    continue
  }
  $script:noMicSaid = $false
  if (-not $recognizer -or -not $mic -or $now.Id -ne $mic.Id) {
    if ($mic -and $now.Id -ne $mic.Id) { Say "The default microphone changed." }
    $mic = $now
    try {
      if ($recognizer) { try { $recognizer.Dispose() } catch { } }
      $recognizer = New-Recognizer
      Say ("Listening on: " + $mic.Name) Green
      $host.UI.RawUI.WindowTitle = "Wake listener: listening on " + $mic.Name
      $since = Get-Date; $script:loudest = 0; $quietWarned = $false
    } catch {
      Say ("Couldn't start listening: " + $_.Exception.Message) Red
      $recognizer = $null
      1..40 | ForEach-Object { Show-Meter; Start-Sleep -Milliseconds 120 }
      continue
    }
  }

  # Listen for one phrase (up to 20 seconds of silence), showing the level meanwhile.
  try {
    $heard = Wait-Windows ($recognizer.RecognizeAsync()) ([Windows.Media.SpeechRecognition.SpeechRecognitionResult]) { Show-Meter }
  } catch {
    $why = $_.Exception; while ($why.InnerException) { $why = $why.InnerException }
    if ($why.HResult -eq -2147199735) { Say "Windows' speech privacy setting is blocking it: turn on Settings > Privacy & security > Speech > Online speech recognition, then restart this." Yellow }
    else { Say ("Listening stopped: " + $why.Message + " Starting again.") Yellow }
    $recognizer = $null
    Start-Sleep -Seconds 2
    continue
  }

  # Silent too long: say so once (the meter should move when you talk).
  if (((Get-Date) - $since).TotalSeconds -ge 20) {
    if ($script:loudest -lt 2 -and -not $quietWarned) { Say ("No sound at all from " + $mic.Name + ": check it isn't muted (Settings > System > Sound > Input) and that it's the microphone you're using.") Yellow; $quietWarned = $true }
    if ($script:loudest -ge 2) { $quietWarned = $false }
    $script:loudest = 0; $since = Get-Date
  }

  switch ([string]$heard.Status) {
    "Success" { }
    "TimeoutExceeded" { continue }
    "MicrophoneUnavailable" { Say ("The microphone " + $mic.Name + " isn't available: another app may be using it only for itself, or desktop apps aren't allowed the microphone (Settings > Privacy & security > Microphone).") Yellow; $recognizer = $null; Start-Sleep -Seconds 3; continue }
    "UserCanceled" { continue }
    default { Say ("Listening issue: " + $heard.Status + ". Starting again.") Yellow; $recognizer = $null; Start-Sleep -Seconds 2; continue }
  }

  $sure = $heard.RawConfidence
  $pct = "{0:0}%" -f ($sure * 100)
  if (-not $heard.Text -or [string]$heard.Confidence -eq "Rejected") {
    Say "Heard talking, not the phrase." DarkGray
  } elseif ($sure -lt $MinConfidence) {
    Say ("Heard something like `"" + $heard.Text + "`" but only $pct sure: ignored. Say it again, a little clearer.") Yellow
  } elseif (((Get-Date) - $last).TotalSeconds -lt $CooldownSecs) {
    Say ("Heard `"" + $heard.Text + "`" ($pct): just opened it, ignored.") DarkGray
  } else {
    Say ("Heard `"" + $heard.Text + "`" ($pct): opening the assistant.") Cyan
    $last = Get-Date
    try { Open-Assistant } catch { Say ("Couldn't open the assistant: " + $_.Exception.Message) Red }
  }
}
