# Wake listener

Say **"hey Tyrone"** and your Project Check-in assistant opens and starts talking.

Since 6.0 the listening is done by a **neural keyword engine** ([sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) keyword spotting). It's a small model trained on thousands of hours of real speech, so it hears the phrase from across the room and over music, in anyone's voice, with nothing to train. It runs on your PC; nothing is sent anywhere.

## Install

1. Download the latest version from **[Releases](https://github.com/LimestoneTechnologyGroup/wake-listener/releases/latest)**: the file named with its version, such as `WakeListener-6.3.1.zip` (`WakeListener.zip` there is the same file). Right-click it, **Extract All**, and put the folder somewhere it can stay, such as Documents. (From 6.1 on it updates itself. Updating from an older version by hand: Quit from the tray first, then extract over the same folder.)
2. Double-click **Start wake listener.cmd**. (If Windows asks about running it, choose **Run**.)
3. **First run: it sets up the engine** (a few minutes, once, needs the internet). The activity window shows each step:
   - Python: it uses yours (3.11 to 3.14), or installs Python 3.12 from python.org for your Windows account only, through winget;
   - its own Python environment and the engine's packages (sherpa-onnx, sounddevice, numpy, sentencepiece), in `%LOCALAPPDATA%\WakeListener`;
   - the 17 MB English model from sherpa-onnx's releases, checked against its published SHA-256 before it's used.
4. Say **"hey Tyrone"**: an Edge app window opens on the assistant and the voice starts. The first time, allow the microphone for the site, and sign in if asked.

**Floating Tyrone** stays on top of every window, above the clock to start with:
- a dot and a word say how Tyrone is: green **Listening** (with a small bar that moves with your voice), blue **Talking** (the assistant is open), grey **Paused**, amber **Setting up**, red **No microphone**;
- **Start** opens Tyrone; **Stop** ends the conversation the same way End discussion does, so it's saved (the page ends it on Escape);
- under it, what you choose from **Show on the button**: to-dos due today, Kitchen orders, your next meeting, your last talk with Tyrone. The first time, **click the button** (or right-click > Show on the button > Connect to Project Check-in): a Project Check-in page opens, you press **Connect**, and it hands the listener a key on this PC. The key is kept encrypted for your Windows account only, and you can revoke it on the Datalink page. (Or paste a key yourself: right-click > Show on the button > Paste a key instead.);
- **Tyrone's window hides itself** a few seconds after he starts talking, so only Floating Tyrone shows and he keeps going. **Click** the button to show his window, click again to hide it. Turn the hiding off with "Hide Tyrone's window while he talks" on the menu. (Closing his window with its X still ends the conversation: use Stop, or just leave it hidden.);
- **double-click** it for the activity window, **drag** it anywhere (it remembers where), **right-click** it for the menu.

The **activity window** (what it's doing, with a live mic meter) is hidden until you double-click Floating Tyrone or choose it from the menu. Closing it only hides it; the listener keeps running.

It also runs as a **tray icon** by the clock. Hover it to see the microphone and the last time it opened. Right-click it (or the floating button) to:
- show the activity window (microphone, live level meter, and each time it hears the phrase),
- pause,
- hide or show the floating button,
- set the **sensitivity** (low, normal, high; it remembers your choice),
- open the assistant now,
- set up the engine again,
- check for updates,
- quit.

**Updates install themselves** (since 6.1): on start and once a day it checks for a newer release, checks the download's SHA-256, installs it over these files and starts again. Never while the assistant is open. To turn that off, add a line `auto-update=no` to `%LOCALAPPDATA%\WakeListener\settings.txt`; "Check for updates" on the menu still works.

While the assistant is open it lets go of the microphone, and takes it back when the assistant closes.

**Start with Windows:** press Win+R, type `shell:startup`, press Enter, and put a shortcut to **Start wake listener.cmd** in that folder.

**Which version you have:** it's at the top of the right-click menu, and in the tray icon's hover text.

**Stop:** right-click the tray icon > Quit.

## Getting the best from it

- **Use the microphone over USB, not Bluetooth, if it has both.** While a Bluetooth headset or speakerphone has its mic on, it sends narrowband, phone-call-quality sound, which loses much of what the engine listens for. Over USB it sends full-quality sound.
- **It misses you:** set the sensitivity to **High** from the tray icon.
- **It opens on other talk:** set it to **Low**.
- Say it the way you'd say "Alexa": "hey Tyrone", then a short pause.

## Settings

At the top of `WakeListener.ps1` (open it in Notepad):
- the phrase (two or three words work best),
- the page it opens and the browser,
- the starting sensitivity,
- the assistant window title it watches for.

Quit from the tray and start it again after a change.

## Check it without a microphone

```
powershell -ExecutionPolicy Bypass -File WakeListener.ps1 -Test
```

Windows' own voices say "hey Tyrone" at different speeds, some over loud music, and other things that come close ("Tyrone called about the permit", "my brother Tyrone", "hey there Ron", "hey Tony", "high tone"). Each recording goes through the engine the way the microphone's sound does: the phrase must open, the others mustn't. The engine has to be set up first, by starting the listener once.

## How it works

- `WakeListener.ps1` is the tray app: it follows the default microphone, starts `listen.py`, reads what it prints, opens the assistant, and hands the microphone over while the assistant is open.
- `listen.py` reads the microphone (sounddevice), evens out the level (slow automatic gain, so quiet or far-off talk is brought up), and runs sherpa-onnx's streaming keyword spotter on it. The phrase is turned into the model's word pieces when it starts, so another phrase works without retraining. "hi Tyrone" also counts.
- The sensitivity sets the spotter's threshold and how strongly the phrase is favoured. "Normal" caught every test phrase, clean and over music, with no false opens over five minutes of tricky talk.

Earlier versions:
- **5.x** compared the microphone's sound with recordings of your voice. That couldn't cope with distance, music or a Bluetooth mic.
- **Up to 4.x** used Windows' speech recognizers. They were inaccurate with a headset and, in the background, stopped hearing after the first call.

## Why not an exe

1.0.0 and 1.1.0 were a small unsigned tray exe. Windows Defender flagged a downloaded copy (`Behavior:Win32/Persistence.A!ml`, then `Trojan:Win32/Wacatac.H!ml`), as it often does with new unsigned programs that use the microphone. The script does the same job inside Windows' own signed PowerShell, with the engine in Python. The exe source (`WakeListener.cs`, `build.ps1`) is kept for when it can be code-signed.
