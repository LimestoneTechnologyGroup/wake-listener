# Wake listener

Say **"hey assistant"** (or "okay assistant") and your Project Check-in assistant opens and starts talking. A small Windows tray app.

## Install

1. Download **[WakeListener.exe](https://github.com/LimestoneTechnologyGroup/wake-listener/releases/latest/download/WakeListener.exe)** and put it somewhere it can stay, such as Documents.
2. Double-click it. If Windows says it protected your PC, choose **More info**, then **Run anyway** (the app isn't code-signed).
3. A tray icon appears and it's listening. To have it start with Windows, right-click the icon and tick **Start with Windows** (a shortcut in your Startup folder).

It doesn't install or copy itself anywhere. The first time it opens the assistant, allow the microphone for the site, and sign in if asked.

## How it works

- Windows' own offline speech recognizer listens for the phrase on your default microphone. Nothing is recorded or sent anywhere until you say it.
- When it hears the phrase, it opens the assistant's voice page (`/assistant?start=voice`) in an Edge app window, which starts the conversation by itself.
- Right-click the tray icon to open the assistant now, pause listening, tick or untick Start with Windows, open the settings or the log, or quit.

## Settings

`%LOCALAPPDATA%\WakeListener\wake-listener.ini` (tray icon > Open settings): the phrases, the page it opens, the browser, how sure it must be (`confidence`), and the cooldown. Quit and start it again after a change.

## Remove

Tray icon > untick Start with Windows, then Quit, and delete the exe. Or run `uninstall.ps1` from this repo, which also removes what 1.0.0 set up.

## Upgrading from 1.0.0

1.0.0 copied itself into `%LOCALAPPDATA%\WakeListener` and added a registry Run key. Windows Defender flagged that as `Behavior:Win32/Persistence.A!ml`. Let Defender remove it (or run `uninstall.ps1`), then use 1.1.0.

## Build

`build.ps1` compiles `WakeListener.cs` with the C# compiler that ships with Windows (.NET Framework 4). `WakeListener.exe --test` checks the phrases match, other words don't, and Start with Windows toggles.
