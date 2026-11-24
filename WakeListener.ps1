# Wake listener: say "hey assistant" and your Project Check-in assistant opens.
#
# Plain PowerShell, no exe: Windows' own offline speech recognizer listens on
# your default microphone. Nothing is recorded or sent anywhere. When it hears
# the phrase, it opens the assistant's voice page, which starts talking by itself.
#
# Run it: right-click this file > Run with PowerShell (or double-click
# "Start wake listener.cmd"). Leave the window open; minimize it. Close it to stop.
# Check it without a microphone: WakeListener.ps1 -Test

param([switch]$Test)

# ---- Settings ---------------------------------------------------------------
$Phrases       = @("hey assistant", "okay assistant")   # what to say, lowercase
$Url           = "https://project-checkin.dev.limestonetg.com/assistant?start=voice"
$Browser       = "edge-app"   # edge-app, chrome-app, or default
$MinConfidence = 0.5          # raise it if it opens by mistake; lower it if it misses you
$CooldownSecs  = 45           # ignore the phrase this long after opening
# -----------------------------------------------------------------------------

Add-Type -AssemblyName System.Speech
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

function Test-Grammar {
  $engine.SetInputToNull()
  $ok = $true
  foreach ($p in $Phrases) {
    $r = $engine.EmulateRecognize($p)
    $hit = $r -and $r.Grammar.Name -eq "wake"
    Write-Host ("{0,-9} {1}" -f $(if ($hit) { "match" } else { "NO MATCH" }), $p)
    $ok = $ok -and $hit
  }
  $r = $engine.EmulateRecognize("send the budget to finance")
  $miss = -not ($r -and $r.Grammar.Name -eq "wake")
  Write-Host ("{0,-9} send the budget to finance" -f $(if ($miss) { "ignored" } else { "MATCHED" }))
  return ($ok -and $miss)
}

if ($Test) { if (Test-Grammar) { exit 0 } else { exit 1 } }

function Open-Assistant {
  $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  $chrome = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
  # An app-style window: no tabs or address bar, and the browser lets it start talking straight away.
  if ($Browser -eq "edge-app" -and $edge) { Start-Process $edge "--app=$Url" }
  elseif ($Browser -eq "chrome-app" -and $chrome) { Start-Process $chrome "--app=$Url" }
  else { Start-Process $Url }
}

try {
  $engine.SetInputToDefaultAudioDevice()
} catch {
  Write-Host ""
  $why = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
  Write-Host "The microphone couldn't be opened: $why" -ForegroundColor Yellow
  Write-Host "Check a microphone is plugged in and set as the default recording device"
  Write-Host "(Settings > System > Sound > Input). If it still fails, open Control Panel >"
  Write-Host "Speech Recognition > Set up microphone once, then run this again."
  Read-Host "Press Enter to close"
  exit 1
}

# A click in the window would start text selection, which pauses the script until
# Esc. Turn that off for this window only, so a stray click can't stop it listening.
try {
  Add-Type -Namespace WakeListener -Name Console -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int which);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr handle, out uint mode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr handle, uint mode);
'@
  $in = [WakeListener.Console]::GetStdHandle(-10)
  $mode = 0
  if ([WakeListener.Console]::GetConsoleMode($in, [ref]$mode)) {
    [void][WakeListener.Console]::SetConsoleMode($in, ($mode -band (-bnot 0x40)) -bor 0x80)   # QuickEdit off (extended flags on)
  }
} catch { }

$host.UI.RawUI.WindowTitle = "Wake listener: say `"$($Phrases[0])`""
Write-Host "Wake listener is on. Say `"$($Phrases[0])`" and your assistant opens." -ForegroundColor Green
Write-Host "Minimize this window; close it to stop listening."
Write-Host ""

$last = [datetime]::MinValue
while ($true) {
  $r = $engine.Recognize([TimeSpan]::FromSeconds(30))
  if (-not $r -or $r.Grammar.Name -ne "wake") { continue }
  $when = Get-Date -Format "HH:mm:ss"
  $sure = [math]::Round($r.Confidence, 2)
  if ($r.Confidence -lt $MinConfidence) { Write-Host "$when  Heard `"$($r.Text)`" ($sure): too unsure, ignored."; continue }
  if (((Get-Date) - $last).TotalSeconds -lt $CooldownSecs) { Write-Host "$when  Heard `"$($r.Text)`" ($sure): just opened, ignored."; continue }
  Write-Host "$when  Heard `"$($r.Text)`" ($sure): opening the assistant." -ForegroundColor Cyan
  $last = Get-Date
  try { Open-Assistant } catch { Write-Host "$when  Couldn't open the assistant: $($_.Exception.Message)" -ForegroundColor Yellow }
}
