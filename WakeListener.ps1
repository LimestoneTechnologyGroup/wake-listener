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

$Version = "3.1.0"

# ---- Settings ---------------------------------------------------------------
$Phrases       = @("hey assistant", "okay assistant", "hi assistant", "ok assistant")   # what to say, lowercase
$Url           = "https://project-checkin.dev.limestonetg.com/assistant?start=voice"
$Browser       = "edge-app"   # edge-app, chrome-app, or default
# How sure Windows must be: High, Medium or Low (its own verdict). Low opens on
# anything it didn't reject; raise it to Medium if it ever opens by mistake.
$MinVerdict    = "Low"
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
$asTaskAction = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq "AsTask" -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' } | Select-Object -First 1
function Wait-WindowsAction($action) { $task = $asTaskAction.Invoke($null, @($action)); $null = $task.Wait(10000) }

# Continuous listening keeps the microphone open all the time (no gaps, and a
# Bluetooth mic's audio link stays up). Its results arrive as Windows events,
# which PowerShell can't subscribe to, so a few lines of C# collect them into a
# queue this script reads. Built once with Windows' own C# compiler into the
# user's temp folder, and rebuilt only when this code changes.
$speechHelper = @'
using System.Collections.Concurrent;
using Windows.Media.SpeechRecognition;
namespace WakeListenerSpeech {
  public static class Continuous {
    public static readonly ConcurrentQueue<string> Heard = new ConcurrentQueue<string>();
    public static void Attach(SpeechRecognizer r) {
      r.ContinuousRecognitionSession.ResultGenerated += (s, e) => Heard.Enqueue("result|" + e.Result.Confidence + "|" + e.Result.RawConfidence.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + e.Result.Text);
      r.ContinuousRecognitionSession.Completed += (s, e) => Heard.Enqueue("completed|" + e.Status);
    }
  }
}
'@
$fw = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319"
$helperHash = [BitConverter]::ToString((New-Object System.Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($speechHelper))).Replace("-", "").Substring(0, 12)
$helperDll = Join-Path $env:TEMP "WakeListenerSpeech-$helperHash.dll"
if (-not (Test-Path $helperDll)) {
  $helperCs = Join-Path $env:TEMP "WakeListenerSpeech-$helperHash.cs"
  Set-Content $helperCs $speechHelper -Encoding UTF8
  $refs = @("$env:WINDIR\System32\WinMetadata\Windows.Media.winmd", "$env:WINDIR\System32\WinMetadata\Windows.Foundation.winmd", "$fw\System.Runtime.WindowsRuntime.dll", "$fw\System.Runtime.dll", "$fw\System.Runtime.InteropServices.WindowsRuntime.dll", "$fw\System.Threading.Tasks.dll")
  $built = & (Join-Path $fw "csc.exe") /nologo /target:library "/out:$helperDll" ($refs | ForEach-Object { "/reference:$_" }) $helperCs 2>&1
  if ($LASTEXITCODE -ne 0) { throw "The listening helper couldn't be built: $built" }
}
Add-Type -Path $helperDll

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
  $r.Timeouts.BabbleTimeout = [TimeSpan]::FromSeconds(4)
  $r.Timeouts.EndSilenceTimeout = [TimeSpan]::FromMilliseconds(300)
  # Never stop for silence: it listens until told to stop.
  $r.ContinuousRecognitionSession.AutoStopSilenceTimeout = [TimeSpan]::FromDays(7)
  [WakeListenerSpeech.Continuous]::Attach($r)
  return $r
}

# Starts continuous listening; results arrive in the helper's queue.
function Start-Session($r) { Wait-WindowsAction ($r.ContinuousRecognitionSession.StartAsync()) }
function Stop-Session($r) { if ($r) { try { Wait-WindowsAction ($r.ContinuousRecognitionSession.CancelAsync()) } catch { }; try { $r.Dispose() } catch { } } }

if ($Test) {
  $ok = $true
  "speech language: " + [Windows.Media.SpeechRecognition.SpeechRecognizer]::SystemSpeechLanguage.LanguageTag
  try { $r = New-Recognizer; "phrases: ready (" + ($Phrases -join ", ") + ")" } catch { "phrases: FAILED " + $_.Exception.Message; $ok = $false }
  $mic = Get-Microphone
  "microphone: " + $(if ($mic) { $mic.Name + ", level " + [WakeListenerAudio.DefaultMicrophone]::Level() } else { "none on this PC" })
  if ($r) {
    try {
      Start-Session $r
      Start-Sleep -Seconds 3
      $item = $null; $seen = @(); while ([WakeListenerSpeech.Continuous]::Heard.TryDequeue([ref]$item)) { $seen += $item }
      "continuous listening: started" + $(if ($seen) { "; events: " + ($seen -join ", ") } else { "; listening, no events yet" })
      Stop-Session $r
    } catch { "continuous listening: FAILED " + $_.Exception.Message; $ok = $false }
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
function Say([string]$text, [string]$color = "Gray") {
  Clear-Meter
  Write-Host ("{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $text) -ForegroundColor $color
  if ($color -eq "Yellow" -or $color -eq "Red") { Notify $text }
}
$script:loudest = 0
function Show-Meter {
  $level = [WakeListenerAudio.DefaultMicrophone]::Level()
  if ($level -gt $script:loudest) { $script:loudest = $level }
  if ($level -gt $script:windowLoudest) { $script:windowLoudest = $level }
  $state = if ($level -lt 0) { "no microphone" } elseif ($level -ge 8) { "hearing sound" } else { "quiet" }
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
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Icon = [System.Drawing.SystemIcons]::Information
$script:tray.Visible = $true
$script:showItem = New-Object System.Windows.Forms.MenuItem("Show activity window")
$script:showItem.add_Click({ Set-WindowShown (-not $script:windowShown) })
$pauseItem = New-Object System.Windows.Forms.MenuItem("Pause listening")
$pauseItem.add_Click({ $script:paused = -not $script:paused; $this.Text = if ($script:paused) { "Resume listening" } else { "Pause listening" }; Say $(if ($script:paused) { "Paused: it won't open the assistant until you resume." } else { "Resumed." }); Set-TrayText })
$openItem = New-Object System.Windows.Forms.MenuItem("Open the assistant now")
$openItem.add_Click({ try { Open-Assistant } catch { } })
$quitItem = New-Object System.Windows.Forms.MenuItem("Quit (stop listening)")
$quitItem.add_Click({ $script:quit = $true })
$script:tray.ContextMenu = New-Object System.Windows.Forms.ContextMenu(,[System.Windows.Forms.MenuItem[]]@($script:showItem, $pauseItem, $openItem, (New-Object System.Windows.Forms.MenuItem("-")), $quitItem))
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

Clear-Host
Write-Host "Wake listener $Version (Windows speech recognizer)" -ForegroundColor White
Write-Host ("Say " + (($Phrases | Select-Object -First 2 | ForEach-Object { "`"$_`"" }) -join " or ") + " and your assistant opens (when Windows' verdict is $MinVerdict or better).")
Write-Host "Opens: $Url"
Write-Host "This window hides itself: the tray icon by the clock keeps listening, whatever window is in front."
Write-Host "Right-click the tray icon to show this window again, pause, open the assistant, or quit."
Write-Host "(If you click inside this window it pauses until you press Esc.)"
Write-Host ""
Set-TrayText
Idle 2500
Set-WindowShown $false
$script:tray.ShowBalloonTip(6000, "Wake listener is on", "Say `"$($Phrases[0])`" and your assistant opens. It's listening in the tray; right-click the icon for options.", [System.Windows.Forms.ToolTipIcon]::Info)

$recognizer = $null
$mic = $null
$last = [datetime]::MinValue
$since = Get-Date
$quietWarned = $false
$rank = @{ High = 3; Medium = 2; Low = 1; Rejected = 0 }
$nextMicCheck = Get-Date
$restartAt = $null

while (-not $script:quit) {
  # Every few seconds: follow the default microphone, (re)starting on it whenever it changes.
  if ((Get-Date) -ge $nextMicCheck -or ($restartAt -and (Get-Date) -ge $restartAt)) {
    $nextMicCheck = (Get-Date).AddSeconds(3)
    $now = Get-Microphone
    if (-not $now) {
      if ($mic -or -not $script:noMicSaid) { Say "No microphone found. Plug one in or set a default in Settings > System > Sound > Input. Checking every few seconds." Yellow; $script:noMicSaid = $true }
      Stop-Session $recognizer; $recognizer = $null; $mic = $null
      $script:micName = $null; Set-TrayText
    } else {
      $script:noMicSaid = $false
      if (-not $recognizer -or -not $mic -or $now.Id -ne $mic.Id -or $restartAt) {
        if ($mic -and $now.Id -ne $mic.Id) { Say "The default microphone changed." }
        Stop-Session $recognizer; $recognizer = $null
        $mic = $now; $restartAt = $null
        try {
          $recognizer = New-Recognizer
          Start-Session $recognizer
          Say ("Listening on: " + $mic.Name + " (continuously)") Green
          $script:micName = $mic.Name; Set-TrayText
          $host.UI.RawUI.WindowTitle = "Wake listener: listening on " + $mic.Name
          $since = Get-Date; $script:loudest = 0; $script:windowLoudest = 0; $quietWarned = $false
        } catch {
          $why = $_.Exception; while ($why.InnerException) { $why = $why.InnerException }
          if ($why.HResult -eq -2147199735) { Say "Windows' speech privacy setting is blocking it: turn on Settings > Privacy & security > Speech > Online speech recognition. Trying again shortly." Yellow }
          else { Say ("Couldn't start listening: " + $why.Message + " Trying again shortly.") Red }
          Stop-Session $recognizer; $recognizer = $null
          $restartAt = (Get-Date).AddSeconds(5)
        }
      }
    }
  }

  # What it heard (and whether listening stopped), from the helper's queue.
  $item = $null
  while ([WakeListenerSpeech.Continuous]::Heard.TryDequeue([ref]$item)) {
    $parts = $item.Split("|", 4)
    if ($parts[0] -eq "completed") {
      # Listening stopped by itself: say why if it matters, and start again in a moment.
      $status = $parts[1]
      if ($status -eq "MicrophoneUnavailable") { Say ("The microphone " + $mic.Name + " isn't available: another app may be using it only for itself, or desktop apps aren't allowed the microphone (Settings > Privacy & security > Microphone). Trying again shortly.") Yellow }
      elseif ($status -ne "Success" -and $status -ne "TimeoutExceeded" -and $status -ne "UserCanceled") { Say ("Listening stopped (" + $status + "). Starting again.") Yellow }
      if (-not $script:quit) { $restartAt = (Get-Date).AddSeconds(2) }
      continue
    }
    # A result: Windows' verdict (High, Medium, Low, Rejected), its raw score, the words, and how loud the mic got.
    $verdict = $parts[1]
    $raw = [double]::Parse($parts[2], [Globalization.CultureInfo]::InvariantCulture)
    $text = $parts[3]
    $pct = "{0} verdict, {1:0}% raw, mic peak {2}" -f $verdict.ToLowerInvariant(), ($raw * 100), $script:loudest
    $script:loudest = 0
    if (-not $text -or $verdict -eq "Rejected") {
      Say "Heard talking, not the phrase." DarkGray
    } elseif ($rank[$verdict] -lt $rank[$MinVerdict]) {
      Say ("Heard something like `"" + $text + "`" ($pct): not sure enough, ignored. Say it again, a little clearer.") DarkYellow
    } elseif (((Get-Date) - $last).TotalSeconds -lt $CooldownSecs) {
      Say ("Heard `"" + $text + "`" ($pct): just opened it, ignored.") DarkGray
    } elseif ($script:paused) {
      Say ("Heard `"" + $text + "`" ($pct): paused, so not opening.") DarkGray
    } else {
      Say ("Heard `"" + $text + "`" ($pct): opening the assistant.") Cyan
      $script:lastHeard = (Get-Date -Format "HH:mm") + " opened"; Set-TrayText
      $last = Get-Date
      try { Open-Assistant } catch { Say ("Couldn't open the assistant: " + $_.Exception.Message) Red }
    }
  }

  # Silent too long: say so once (the meter should move when you talk).
  if ($recognizer -and ((Get-Date) - $since).TotalSeconds -ge 20) {
    if ($script:windowLoudest -lt 2 -and -not $quietWarned) { Say ("No sound at all from " + $mic.Name + " for 20 seconds: check its mute button and its input volume (Settings > System > Sound > Input).") Yellow; $quietWarned = $true }
    if ($script:windowLoudest -ge 2) { $quietWarned = $false }
    $script:windowLoudest = 0; $since = Get-Date
  }

  [System.Windows.Forms.Application]::DoEvents()
  Show-Meter
  Start-Sleep -Milliseconds 100
}

# Quit from the tray: tidy up.
Stop-Session $recognizer
$script:tray.Visible = $false
$script:tray.Dispose()
