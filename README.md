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
- a dot and a word say how Tyrone is: green **Sleeping** (waiting for "hey Tyrone", with a small bar that moves with your voice), blue **On a call** (only while a conversation is actually connected), light blue **Connecting**, grey **Paused**, amber **Setting up**, red **No microphone**;
- **the arrow** next to Start/Stop opens a **larger view**: each item you chose under its own heading, in full (today's to-dos with the late ones marked, your Kitchen orders, your next meeting with its time, your last talk with what was done). Click it again to go back to the small button; it remembers which you like;
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

## Claude relay (ClaudeRelay.ps1)

Connects Tyrone to your Claude Code threads. Run it on the PC where the Claude desktop app runs your threads, which may not be the PC with the wake listener (for example a desktop you reach over Remote Desktop). Download: the `relay-v…` release (ClaudeRelay.zip), not the wake listener's.

**What's going on.** Every two minutes it reads the desktop app's session files on that PC and sends Project Check-in the list: each thread's name, folder, whether it's working, waiting on you or done, its last report and what it needs from you.

**Jobs: the Tyrone thread (3.0).** Every Claude Code job you ask Tyrone to send goes to one Claude Code thread on the PC, the Tyrone thread. Tyrone reads each job back and sends it only after you say yes. On the PC:

- The Tyrone thread is one Claude Code session in its own folder (`%LOCALAPPDATA%\ClaudeRelay\tyrone`), outside your projects. Each job picks the same session up again (`--resume`), one job at a time, so it remembers the jobs before it. `-Doctor` shows its session.
- It only dispatches, so every change goes on a branch (3.1): even a one-line change goes to a subthread. A job with separate parts gets one subthread per part: it writes a small file into `%LOCALAPPDATA%\ClaudeRelay\spawn` and the relay starts each one, up to 5 at once (more wait their turn). It can stop one it doesn't need with a `stop-<id>.json` file there.
- Each subthread runs in its own git worktree of one project, on its own branch (`tyrone/<name>-<id>`). When it finishes, the relay commits its changes to that branch, removes the worktree and keeps the branch (or deletes it if nothing changed). Nothing is merged into a main branch; that's yours to do, or to ask for. A project without git gets one subthread at a time.
- Only your project folders: folders where a Claude Code thread has run in the last 30 days (never the app's scratch or temp folders).
- Everything runs in the background with this PC's Claude Code (the copy the desktop app keeps), with file edits allowed and any command your project hasn't already allowed refused (`--permission-mode acceptEdits`). 45 minutes at most for each. Cancelling a job on Project Check-in stops it.
- Live: while anything runs, every few seconds it sends what the Tyrone thread and each subthread are doing, step by step ("Reading talk-chat.tsx", "Editing actions.ts", "Running: npm test"), and Talk shows it as it happens. Results go back to Tyrone and your Tyrone chat (each subthread's too), and by phone if you asked for a call back.

Setup:

1. `powershell -ExecutionPolicy Bypass -File ClaudeRelay.ps1 -Connect`, then press **Connect Claude relay** on the page that opens. The key is kept encrypted for your Windows account in `%LOCALAPPDATA%\ClaudeRelay`.
2. `powershell -ExecutionPolicy Bypass -File ClaudeRelay.ps1 -Doctor`. The desktop app signs in only its own threads, so the first time it shows one command to sign Claude Code in for jobs (`claude.exe auth login`, which opens your browser). Run that once yourself.
3. `powershell -ExecutionPolicy Bypass -File ClaudeRelay.ps1 -Install` copies it to `%LOCALAPPDATA%\ClaudeRelay` and starts it hidden at every sign-in (a scheduled task named Claude relay). Run it again after downloading a new version.

`-DryRun` shows what it would send; `-Once` sends the thread list once; `-Uninstall` removes the scheduled task. Its log is `%LOCALAPPDATA%\ClaudeRelay\relay.log`, and each job's and subthread's prompt and output are kept for a week in `%LOCALAPPDATA%\ClaudeRelay\jobs` and `\subthreads`. Revoke the key on Project Check-in's Datalink page.

Tested on 2026-11-26: Tyrone sent a Claude Code job through the relay to this PC.


## Thread driver (ThreadDriver.ps1)

Lets Tyrone type into your real Claude Code threads. Say "tell the project-checkin fork thread to run the tests again": Tyrone reads it back, and on your yes the Thread driver on your PC opens that thread in the Claude desktop app, types the message into its box and presses Enter, exactly as if you'd typed it. The thread works with its own settings (and shows in the app, and on your phone through Remote Control). When it finishes its turn, its answer goes back to Tyrone and your chat.

It needs the Claude relay connected (it uses the relay's key) and a live screen: it waits, and Tyrone says why, while the PC is locked or Remote Desktop to it is disconnected, while the thread is busy, or while there's unsent text in that thread's box (it never overwrites it). It brings the Claude app to the front while it types. It types only after the app is really in front, checks the whole message landed before pressing Enter, and never clicks anything else: it never answers a permission prompt. When a thread stops to ask, Tyrone tells you, and you approve it yourself.

1. Connect the Claude relay first (above).
2. `powershell -ExecutionPolicy Bypass -File ThreadDriver.ps1 -Doctor` checks it can see the Claude app, its message box and the relay's key.
3. `powershell -ExecutionPolicy Bypass -File ThreadDriver.ps1 -Install` copies it to `%LOCALAPPDATA%\ThreadDriver` and starts it hidden at every sign-in (a scheduled task named Thread driver).

`-Type <thread id> "message"` types one message now and waits for the answer (a test). `-Uninstall` removes the scheduled task. Its log is `%LOCALAPPDATA%\ThreadDriver\driver.log`.
