# Wake listener

Say **"hey Tyrone"** (or "okay Tyrone") and your Project Check-in assistant opens and starts talking.

It's a plain PowerShell script, not an exe. Since 3.0 it uses Windows 10/11's built-in speech recognizer (Windows.Media.SpeechRecognition), listening only for a short list of phrases on your default microphone. Nothing is recorded or sent anywhere.

## Install

1. Download **[WakeListener.zip](https://github.com/LimestoneTechnologyGroup/wake-listener/releases/latest/download/WakeListener.zip)**, right-click it, **Extract All**, and put the folder somewhere it can stay, such as Documents.
2. Double-click **Start wake listener.cmd**. It shows a short startup message, then hides itself as a **tray icon** by the clock and keeps listening continuously, whatever window is in front. Hover the icon to see the microphone and the last time it opened; right-click it to show the activity window (which microphone, a live level meter, everything it hears and why it did or didn't open), pause, open the assistant now, or quit. Problems pop up as tray notices. It follows you if you change your default microphone. (If Windows asks about running it, choose **Run**.)
3. Say **"hey Tyrone"**: an Edge app window opens on the assistant and the voice starts. The first time, allow the microphone for the site, and sign in if asked.

**Start with Windows:** press Win+R, type `shell:startup`, press Enter, and put a shortcut to **Start wake listener.cmd** in that folder.

**Stop:** right-click the tray icon > Quit.

## Settings

At the top of `WakeListener.ps1` (open it in Notepad): the phrases, the page it opens, the browser, how sure it must be (`$MinVerdict`), and the assistant window title it watches for. Quit from the tray and start it again after a change.

## If the microphone won't open

Check a microphone is plugged in and set as the default recording device (Settings > System > Sound > Input). If it still fails, open Control Panel > Speech Recognition > **Set up microphone** once, then start it again.

## Check it without a microphone

`powershell -ExecutionPolicy Bypass -File WakeListener.ps1 -Test` checks the phrases match and other words don't.

## Why not an exe

1.0.0 and 1.1.0 were a small unsigned tray exe. Windows Defender flagged a downloaded copy (`Behavior:Win32/Persistence.A!ml`, then `Trojan:Win32/Wacatac.H!ml`), as it often does with new unsigned programs that use the microphone. The script does the same job inside Windows' own signed PowerShell. The exe source (`WakeListener.cs`, `build.ps1`) is kept for when it can be code-signed.
