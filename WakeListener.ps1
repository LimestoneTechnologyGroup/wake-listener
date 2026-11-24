# Wake listener: say "hey assistant" and your Project Check-in assistant opens.
#
# Plain PowerShell, no exe: Windows' own offline speech recognizer listens on
# your default microphone. Nothing is recorded or sent anywhere. When it hears
# the phrase, it opens the assistant's voice page, which starts talking by itself.
#
# The window shows what's going on: which microphone, a live level meter, what
# it hears, and any problem with the sound. It follows you if you change your
# default microphone.
#
# Run it: double-click "Start wake listener.cmd" (or right-click this file >
# Run with PowerShell). Close the window to stop.
# Check it without a microphone: WakeListener.ps1 -Test

param([switch]$Test)

$Version = "2.1.0"

# ---- Settings ---------------------------------------------------------------
$Phrases       = @("hey assistant", "okay assistant")   # what to say, lowercase
$Url           = "https://project-checkin.dev.limestonetg.com/assistant?start=voice"
$Browser       = "edge-app"   # edge-app, chrome-app, or default
$MinConfidence = 0.5          # raise it if it opens by mistake; lower it if it misses you
$CooldownSecs  = 45           # ignore the phrase this long after opening
# -----------------------------------------------------------------------------

Add-Type -AssemblyName System.Speech

# Windows' default recording device: its name and id, from the Core Audio API.
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
  [StructLayout(LayoutKind.Sequential)] struct PropertyKey { public Guid fmtid; public int pid; }
  [StructLayout(LayoutKind.Explicit)] struct PropVariant { [FieldOffset(0)] public short vt; [FieldOffset(8)] public IntPtr pointer; [FieldOffset(8)] public long padding; }
  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }
  public static class DefaultMicrophone {
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant value);
    /// <summary>"id|name" of the default recording device, or "" when there is none.</summary>
    public static string Describe() {
      try {
        var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        IMMDevice device;
        if (enumerator.GetDefaultAudioEndpoint(1, 0, out device) != 0 || device == null) return "";
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
  }
}
'@

function Get-Microphone {
  $d = [WakeListenerAudio.DefaultMicrophone]::Describe()
  if (-not $d) { return $null }
  $i = $d.IndexOf("|")
  return [pscustomobject]@{ Id = $d.Substring(0, $i); Name = $d.Substring($i + 1) }
}

$culture = [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers() |
  ForEach-Object { $_.Culture } | Where-Object { $_.Name -eq "en-US" } | Select-Object -First 1
if (-not $culture) { $culture = ([System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers() | Select-Object -First 1).Culture }
$engine = New-Object System.Speech.Recognition.SpeechRecognitionEngine($culture)

$builder = New-Object System.Speech.Recognition.GrammarBuilder(New-Object System.Speech.Recognition.Choices(,[string[]]$Phrases))
$builder.Culture = $culture
$wake = New-Object System.Speech.Recognition.Grammar($builder)
$wake.Name = "wake"
$engine.LoadGrammar($wake)
# Free dictation beside the phrases: ordinary talk matches dictation instead of
# being forced onto the nearest wake phrase, so it opens by mistake less often.
$other = New-Object System.Speech.Recognition.DictationGrammar
$other.Name = "other"
$engine.LoadGrammar($other)

# The engine reports what it hears, the sound level and sound problems as events, queued here.
$null = Register-ObjectEvent -InputObject $engine -EventName SpeechRecognized -SourceIdentifier WL.Heard
$null = Register-ObjectEvent -InputObject $engine -EventName AudioLevelUpdated -SourceIdentifier WL.Level
$null = Register-ObjectEvent -InputObject $engine -EventName AudioSignalProblemOccurred -SourceIdentifier WL.Problem
$null = Register-ObjectEvent -InputObject $engine -EventName RecognizeCompleted -SourceIdentifier WL.Stopped

if ($Test) {
  $engine.SetInputToNull()
  $ok = $true
  foreach ($p in $Phrases + @("send the budget to finance")) {
    $r = $engine.EmulateRecognize($p)
    $hit = $r -and $r.Grammar.Name -eq "wake"
    $want = $Phrases -contains $p
    Write-Host ("{0,-9} {1}" -f $(if ($hit) { "match" } else { "ignored" }), $p)
    $ok = $ok -and ($hit -eq $want)
  }
  # The event path the live window uses.
  Get-Event | Remove-Event
  $engine.EmulateRecognizeAsync($Phrases[0])
  $e = Wait-Event -SourceIdentifier WL.Heard -Timeout 10
  $evented = $e -and $e.SourceEventArgs.Result.Grammar.Name -eq "wake"
  Write-Host ("{0,-9} event for `"{1}`"" -f $(if ($evented) { "event" } else { "NO EVENT" }), $Phrases[0])
  $mic = Get-Microphone
  Write-Host ("microphone: {0}" -f $(if ($mic) { $mic.Name } else { "none on this PC" }))
  if ($ok -and $evented) { exit 0 } else { exit 1 }
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
function Show-Meter([int]$level, [string]$state) {
  $bars = [Math]::Round([Math]::Min(100, $level) / 100 * 30)
  $line = "  Mic level [" + ("#" * $bars).PadRight(30, ".") + "] " + ("{0,3}" -f $level) + "   " + $state
  [Console]::Write("`r" + $line.PadRight((Width)).Substring(0, (Width)))
  $script:meterShown = $true
}

# Starts listening on the default microphone; says which one, or what's wrong.
function Start-Listening {
  $script:mic = Get-Microphone
  if (-not $script:mic) {
    Say "No microphone found. Plug one in or set a default in Settings > System > Sound > Input. Checking again every few seconds." Yellow
    return $false
  }
  try {
    $engine.SetInputToDefaultAudioDevice()
    $engine.RecognizeAsync([System.Speech.Recognition.RecognizeMode]::Multiple)
    Say ("Listening on: " + $script:mic.Name) Green
    $host.UI.RawUI.WindowTitle = "Wake listener: listening on " + $script:mic.Name
    return $true
  } catch {
    $why = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
    Say ("The microphone " + $script:mic.Name + " couldn't be opened: " + $why) Yellow
    Say "If it keeps happening, open Control Panel > Speech Recognition > Set up microphone once." Yellow
    return $false
  }
}

function Stop-Listening {
  try { $engine.RecognizeAsyncCancel() } catch { }
  $null = Wait-Event -SourceIdentifier WL.Stopped -Timeout 3
  Get-Event -SourceIdentifier WL.Stopped -ErrorAction SilentlyContinue | Remove-Event
}

Clear-Host
Write-Host "Wake listener $Version" -ForegroundColor White
Write-Host ("Say " + (($Phrases | ForEach-Object { "`"$_`"" }) -join " or ") + " and your assistant opens (when it's at least {0:0}% sure)." -f ($MinConfidence * 100))
Write-Host "Opens: $Url"
Write-Host "Don't click inside this window: a click pauses it until you press Esc. Close it to stop."
Write-Host ""

$listening = Start-Listening
$last = [datetime]::MinValue
$level = 0; $loudest = 0; $since = Get-Date
$lastCheck = Get-Date
$problemSaid = @{}
$state = "waiting for the phrase"

while ($true) {
  $events = @(Get-Event -ErrorAction SilentlyContinue)
  if (-not $events.Count) { Start-Sleep -Milliseconds 150; $events = @(Get-Event -ErrorAction SilentlyContinue) }
  foreach ($e in $events) {
    Remove-Event -EventIdentifier $e.EventIdentifier -ErrorAction SilentlyContinue
    switch ($e.SourceIdentifier) {
      "WL.Level" { $level = $e.SourceEventArgs.AudioLevel; if ($level -gt $loudest) { $loudest = $level } }
      "WL.Problem" {
        $p = [string]$e.SourceEventArgs.AudioSignalProblem
        if (-not $problemSaid[$p] -or ((Get-Date) - $problemSaid[$p]).TotalSeconds -gt 30) {
          $problemSaid[$p] = Get-Date
          $words = @{ NoSignal = "No sound from the microphone: is it muted, or the wrong one?"; TooSoft = "Too quiet: speak up or move closer to the microphone."; TooNoisy = "Too much background noise to hear the phrase clearly."; TooLoud = "Too loud: the sound is distorted."; TooFast = "That was quick: say the phrase a little slower."; TooSlow = "That was slow: say the phrase a little faster." }
          if ($words[$p]) { Say $words[$p] Yellow }
        }
      }
      "WL.Heard" {
        $r = $e.SourceEventArgs.Result
        $sure = "{0:0}%" -f ($r.Confidence * 100)
        if ($r.Grammar.Name -ne "wake") {
          $said = $r.Text; if ($said.Length -gt 50) { $said = $said.Substring(0, 50) + "..." }
          Say ("Heard `"" + $said + "`": not the phrase.") DarkGray
        } elseif ($r.Confidence -lt $MinConfidence) {
          Say ("Heard `"" + $r.Text + "`" but only $sure sure: ignored. Say it again, a little clearer.") Yellow
        } elseif (((Get-Date) - $last).TotalSeconds -lt $CooldownSecs) {
          Say ("Heard `"" + $r.Text + "`" ($sure): just opened it, ignored.") DarkGray
        } else {
          Say ("Heard `"" + $r.Text + "`" ($sure): opening the assistant.") Cyan
          $last = Get-Date
          try { Open-Assistant } catch { Say ("Couldn't open the assistant: " + $_.Exception.Message) Red }
        }
      }
    }
  }

  # Every few seconds: follow a change of default microphone, and flag a silent one.
  if (((Get-Date) - $lastCheck).TotalSeconds -ge 3) {
    $lastCheck = Get-Date
    $now = Get-Microphone
    $changed = ($now -and -not $script:mic) -or (-not $now -and $script:mic) -or ($now -and $script:mic -and $now.Id -ne $script:mic.Id)
    if ($changed -or (-not $listening -and $now)) {
      if ($listening) { Say "The default microphone changed." ; Stop-Listening }
      $listening = Start-Listening
      $loudest = 0; $since = Get-Date
    }
    if ($listening -and ((Get-Date) - $since).TotalSeconds -ge 20) {
      if ($loudest -eq 0) { Say ("No sound at all from " + $script:mic.Name + " for 20 seconds: check it isn't muted and that it's the microphone you're using.") Yellow }
      $loudest = 0; $since = Get-Date
    }
  }

  if ($listening) { Show-Meter $level $(if ($level -gt 5) { "hearing sound" } else { "quiet" }) } else { Show-Meter 0 "not listening" }
}
