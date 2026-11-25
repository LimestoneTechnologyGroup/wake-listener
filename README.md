# Wake listener

Say **"hey Tyrone"** and your Project Check-in assistant opens and starts talking.

It's a plain PowerShell script, not an exe. It learns **your** voice: the first time it runs, you say "hey Tyrone" eight times and read a few sentences aloud. From then on it compares everything the microphone hears with those recordings and opens the assistant when it hears the phrase, whatever window is in front. No speech recognizer and nothing sent anywhere: the recordings stay on your PC in `%APPDATA%\WakeListener\voice`.

## Install

1. Download **[WakeListener.zip](https://github.com/LimestoneTechnologyGroup/wake-listener/releases/latest/download/WakeListener.zip)**, right-click it, **Extract All**, and put the folder somewhere it can stay, such as Documents. (Updating: Quit from the tray first, then extract over the same folder. Your voice recordings are kept.)
2. Double-click **Start wake listener.cmd**. (If Windows asks about running it, choose **Run**.)
3. **First run: teach it your voice** (about a minute), with the microphone you'll use day to day:
   - stay quiet for two seconds while it measures the room,
   - say "hey Tyrone" when asked, eight times, pausing after each,
   - read the short paragraph it shows, in your normal voice.

   It says how well your recordings match each other, then starts listening.
4. Say **"hey Tyrone"**: an Edge app window opens on the assistant and the voice starts. The first time, allow the microphone for the site, and sign in if asked.

It runs as a **tray icon** by the clock. Hover it to see the microphone and the last time it opened. Right-click it to show the activity window (microphone, live level meter, and every bit of talking it hears with how close it was to your phrase: 100% opens), pause, **teach it your voice again**, open the assistant now, or quit. While the assistant is open it lets go of the microphone, and takes it back when the assistant closes.

**Start with Windows:** press Win+R, type `shell:startup`, press Enter, and put a shortcut to **Start wake listener.cmd** in that folder.

**Stop:** right-click the tray icon > Quit.

## If it misses you, or opens by mistake

- Open the activity window and watch the percentages as you talk.
- **It misses you, and "hey Tyrone" shows 85–99%:** teach it your voice again (from the tray icon) in the place and with the mic you normally use. Or raise `$Sensitivity` at the top of `WakeListener.ps1` from 1.0 to 1.1.
- **It opens on other talk:** lower `$Sensitivity` to 0.9.
- **You change microphones** (say, a headset to a desk mic): teach it your voice again on the new one.

## Settings

At the top of `WakeListener.ps1` (open it in Notepad):
- the phrase training asks for,
- the page it opens and the browser,
- `$Sensitivity`,
- how many recordings training takes,
- the assistant window title it watches for.

Quit from the tray and start it again after a change.

## Check it without a microphone

```
powershell -ExecutionPolicy Bypass -File WakeListener.ps1 -Test
```

It trains on Windows' own voices saying "hey Tyrone". It then checks that new ones open, at different speeds, and that other talk doesn't (including "Tyrone called about the permit" and "hey there Ron"), through the same path the microphone's sound takes.

## How it works

`VoiceMatch.cs` is compiled by PowerShell when the listener starts.
- **Cutting the sound:** it reads the default microphone and cuts the sound into bits of talking, against the room's own background level.
- **Fingerprints:** it turns each bit into a voice fingerprint (MFCCs over 100–4000 Hz, so a Bluetooth headset works too).
- **Matching:** it finds the best fit of your recordings inside each bit, allowing for saying it faster or slower (dynamic time warping).
- **Where it opens:** training sets that point between how close your own recordings are to each other and how close your ordinary talk gets.

Versions up to 4.x used Windows' speech recognizers instead. They were inaccurate with a headset and, in the background, stopped hearing after the first call.

## Why not an exe

1.0.0 and 1.1.0 were a small unsigned tray exe. Windows Defender flagged a downloaded copy (`Behavior:Win32/Persistence.A!ml`, then `Trojan:Win32/Wacatac.H!ml`), as it often does with new unsigned programs that use the microphone. The script does the same job inside Windows' own signed PowerShell. The exe source (`WakeListener.cs`, `build.ps1`) is kept for when it can be code-signed.
