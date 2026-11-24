# Wake listener

Say **"hey assistant"** (or "okay assistant") and your Project Check-in assistant opens and starts talking. A small Windows tray app.

## Install

1. Download **[WakeListener.exe](https://github.com/LimestoneTechnologyGroup/wake-listener/releases/latest/download/WakeListener.exe)**.
2. Double-click it. If Windows says it protected your PC, choose **More info**, then **Run anyway** (the app isn't code-signed).
3. That's it: it installs itself into `%LOCALAPPDATA%\WakeListener` (no admin needed), starts with Windows, and shows a tray icon.

The first time it opens the assistant, allow the microphone for the site, and sign in if asked.

## How it works

- Windows' own offline speech recognizer listens for the phrase on your default microphone. Nothing is recorded or sent anywhere until you say it.
- When it hears the phrase, it opens the assistant's voice page (`/assistant?start=voice`) in an Edge app window, which starts the conversation by itself.
- Right-click the tray icon to open the assistant now, pause listening, turn off "Start with Windows", open the settings or the log, or quit.

## Settings

`%LOCALAPPDATA%\WakeListener\wake-listener.ini` (tray icon > Open settings): the phrases, the page it opens, the browser, how sure it must be (`confidence`), and the cooldown. Quit and start it again after a change.

## Remove

Tray icon > Quit, then delete `%LOCALAPPDATA%\WakeListener`, or run `uninstall.ps1` from this repo.

## Build

`build.ps1` compiles `WakeListener.cs` with the C# compiler that ships with Windows (.NET Framework 4); `WakeListener.exe --test` checks the phrases match and other words don't.
