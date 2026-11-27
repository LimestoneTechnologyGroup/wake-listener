# Wake listener

Say **"hey Smokey"** and your Project Check-in assistant opens and starts talking. ("hey Tyrone", the assistant's old name, still works for a few weeks, since 6.7.)

Since 6.5 it listens in **two stages, the way smart speakers do**. A small keyword spotter ([sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)) catches anything like the phrase, a voice detector passes on every short burst of speech, and since 6.6 detectors trained on the phrases themselves listen too. A speech-to-text model ([Moonshine](https://github.com/moonshine-ai/moonshine)) then checks the words before Smokey opens. It runs on your PC; nothing is sent anywhere.

## Install

1. Download the latest version from **[Releases](https://github.com/LimestoneTechnologyGroup/wake-listener/releases/latest)**: the file named with its version, such as `WakeListener-6.8.0.zip` (`WakeListener.zip` there is the same file). Right-click it, **Extract All**, and put the folder somewhere it can stay, such as Documents. (From 6.1 on it updates itself. Updating from an older version by hand: Quit from the tray first, then extract over the same folder.)
2. Double-click **Start wake listener.cmd**. (If Windows asks about running it, choose **Run**.)
3. **First run: it sets up the engine** (a few minutes, once, needs the internet). The activity window shows each step:
   - Python: it uses yours (3.11 to 3.14), or installs Python 3.12 from python.org for your Windows account only, through winget;
   - its own Python environment and the engine's packages (sherpa-onnx, sounddevice, numpy, sentencepiece, onnxruntime), in `%LOCALAPPDATA%\WakeListener`;
   - three models from sherpa-onnx's releases (the 17 MB keyword spotter, the 106 MB speech-to-text check and a 0.2 MB voice detector) and two from openWakeWord's (2.4 MB, the trained detector's front end), each checked against its SHA-256 before it's used. Updating downloads whatever's new once.
4. Say **"hey Smokey"**: an Edge app window opens on the assistant and the voice starts. The first time, allow the microphone for the site, and sign in if asked.

**Floating Smokey** stays on top of every window, above the clock to start with:
- a word and a shape (never colour alone; since 6.8) say how Smokey is: a filled circle **Sleeping** (waiting for "hey Smokey", with a small bar that moves with your voice), a circle in a ring **On a call** (only while a conversation is actually connected), a ring **Connecting**, **Starting** or **Setting up**, two bars **Paused**, a down arrow **Updating to 6.8.1...**, a warning triangle **No microphone** (Windows has no recording device: it picks one up within a few seconds of it appearing) or **Engine stopped** (there's a microphone, but the listening engine failed: the activity window says why, and it keeps retrying). The version it's running is the small number after the word;
- a strip along the bottom when something needs you (since 6.8): **Update available: 6.8.1. Click here to install it.**, **Updating to 6.8.1... not listening for a minute.**, **Updated to 6.8.1.** (for two minutes), or **Update to 6.8.1 didn't install**, why, and that the old version is still running (click it to try again). With **Show SmokeMonitor alerts** on, an open incident shows there too ("SmokeMonitor: Kitchen site is down (Critical) since 2:05 PM"), and the larger view lists every open one under a SmokeMonitor heading, or "All clear". Updates come first, since they need you;
- **the arrow** next to Start/Stop opens a **larger view**: each item you chose under its own heading, in full (today's to-dos with the late ones marked, your Kitchen orders, your next meeting with its time, your last talk with what was done). Click it again to go back to the small button; it remembers which you like;
- **Start** opens Smokey; **Stop** ends the conversation the same way End discussion does, so it's saved (the page ends it on Escape);
- under it, what you choose from **Show on the button**: to-dos due today, Kitchen orders, your next meeting, your last talk with Smokey. The first time, **click the button** (or right-click > Show on the button > Connect to Project Check-in): a Project Check-in page opens, you press **Connect**, and it hands the listener a key on this PC. The key is kept encrypted for your Windows account only, and you can revoke it on the Datalink page. (Or paste a key yourself: right-click > Show on the button > Paste a key instead.);
- **Smokey's window hides itself** a few seconds after he starts talking, so only Floating Smokey shows and he keeps going. **Click** the button to show his window, click again to hide it. Turn the hiding off with "Hide Smokey's window while he talks" on the menu. (Closing his window with its X still ends the conversation: use Stop, or just leave it hidden.);
- **double-click** it for the activity window, **drag** it anywhere (it remembers where), **right-click** it for the menu.

The **activity window** (what it's doing, with a live mic meter) is hidden until you double-click Floating Smokey or choose it from the menu. Closing it only hides it; the listener keeps running.

It also runs as a **tray icon** by the clock. Hover it to see the microphone and the last time it opened. Right-click it (or the floating button) to:
- show the activity window (microphone, live level meter, and each time it hears the phrase),
- pause,
- hide or show the floating button,
- set the **sensitivity** (low, normal, high; it remembers your choice),
- **He missed me just now**: keeps the last 8 seconds of sound (in `%LOCALAPPDATA%\WakeListener\missed`, on this PC only), with the words it heard in them, so it can be tuned to your voice and room,
- **Open what he heard**: `heard.log`, every time it opened and every close call it turned down, with the words it heard (never your other talk),
- open the assistant now,
- set up the engine again,
- check for updates,
- **Show SmokeMonitor alerts** (off unless you turn it on): open incidents and outages from SmokeMonitor on the button, read once a minute with the same key as your day, and cleared when they resolve. It only shows them: no sound or flashing, since SmokeMonitor already messages and calls for alerts,
- quit.

**Updates install themselves** (since 6.1): on start and every 6 hours (since 6.8; one small request to GitHub) it checks for a newer release, checks the download's SHA-256, installs it over these files and starts again. The button shows each step (above). Never while the assistant is open: it waits until it closes. Listening stops for the minute an update takes. To install only when you click, add a line `auto-update=no` to `%LOCALAPPDATA%\WakeListener\settings.txt`: the button then shows "Update available" until you click it, and "Check for updates" on the menu still works.

While the assistant is open it lets go of the microphone, and takes it back when the assistant closes.

**Start with Windows:** press Win+R, type `shell:startup`, press Enter, and put a shortcut to **Start wake listener.cmd** in that folder.

**Which version you have:** it's at the top of the right-click menu, and in the tray icon's hover text.

**Stop:** right-click the tray icon > Quit.

## Getting the best from it

- **Use the microphone over USB, not Bluetooth, if it has both.** While a Bluetooth headset or speakerphone has its mic on, it sends narrowband, phone-call-quality sound, which loses much of what the engine listens for. Over USB it sends full-quality sound. The activity window says so when the microphone looks like Bluetooth.
- **It misses you:** right after, choose **He missed me just now** from the menu. Then set the sensitivity to **High** if it keeps happening.
- **It opens on other talk:** set it to **Low**.
- Say it the way you'd say "Alexa": "hey Smokey", then a short pause.

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

Windows' own voices say "hey Smokey" and "hey Tyrone" at different speeds, some over loud music, and other things that come close ("we drove through the Smoky Mountains", "Smokey is the Tennessee mascot", "the smoke detector is beeping", "hey Mikey", "Tyrone called about the permit", "my brother Tyrone", "hey there Ron", "hey Tony", "high tone"). Each recording goes through the engine the way the microphone's sound does: the phrase must open, the others mustn't. The engine has to be set up first, by starting the listener once.

How each version compares, on 81 "hey Tyrone" recordings and 420 near misses (three Windows voices, three speeds, sound made to match each room):

| Sound | 6.4 caught | 6.5 caught | 6.6 caught | False opens, 6.4 / 6.5 / 6.6 |
|---|---|---|---|---|
| Close to the mic | 93% | 99% | 100% | 3 / 3 / 3 |
| Bluetooth (phone quality) | 88% | 99% | 100% | 1 / 1 / 1 |
| Across a room | 49% | 80% | 83% | 6 / 5 / 6 |
| Over music | 67% | 94% | 93% | 3 / 3 / 3 |
| Across a room, with music | 26% | 60% | 78% | 4 / 4 / 5 |
| Another room | 4% | 21% | 23% | 1 / 2 / 2 |

The false opens all come from the 240 deliberately close phrases ("hey Tyrion", "hey, tie the rope", "hey Cairo"). None came from the 180 everyday ones. 6.7 listens for both names and scores the same on "hey Tyrone".

"Hey Smokey" in 6.7, on the same kind of test (81 recordings; 180 everyday phrases, including "we drove through the Smoky Mountains", "Smokey is the Tennessee mascot" and "the smoke detector is beeping"; 240 deliberately close ones such as "hey Spooky", "hey, smoke it", "hey Monkey", "hey, it's Smokey's turn"):

| Sound | Caught | False opens (everyday / close) |
|---|---|---|
| Close to the mic | 98% | 0 / 0 |
| Bluetooth (phone quality) | 90% | 0 / 5 |
| Across a room | 68% | 0 / 7 |
| Over music | 98% | 0 / 6 |
| Across a room, with music | 63% | 0 / 10 |
| Another room | 27% | 1 / 2 |

"Smokey" is nearly an everyday word, so it's held to stricter rules than "Tyrone": the words must say "hey" (or "hi", "hello", "okay") right before it, spelled like the name ("Smoky", "Smokie", and "smoking", which speech-to-text often writes for it), and the name alone at the start of a sentence never counts. That keeps "the Smoky Mountains" and the mascot quiet, at the cost of fewer catches across a room than "hey Tyrone".

## How it works

- `WakeListener.ps1` is the tray app: it follows the default microphone, starts `listen.py`, reads what it prints, opens the assistant, and hands the microphone over while the assistant is open.
- `listen.py` reads the microphone (sounddevice) and evens out the level (slow automatic gain, so quiet or far-off talk is brought up). Three things listen to it:
  - **the spotter as before 6.5** (sherpa-onnx keyword spotting on the phrase's own spelling): opens unless the check's words are plainly something else;
  - **the spotter set loose**, with sound-alike spellings of the name ("tie rone", "ty ron"): opens if the check's words have the name (or near it) at the start;
  - **the trained detectors** (6.6, below; one per name since 6.7): when one scores the sound as its phrase, the check runs, and opens only if the words hold a greeting right before the name ("Tyrone's report is late" and "hey, it's Tyrone's turn" don't);
  - **the voice detector** (Silero): every short burst of speech is checked, and opens only if the words clearly hold "hey" or "hi" right before the name. This catches the times the spotter misses.
- **The check** is Moonshine's base English model: it turns the last couple of seconds into words in about 40 ms. Names come out spelled many ways ("Tyron", "Detyrone", "Hey, chiron"), so the words are compared by a rough sound key, and everyday words run together ("try one") don't count.
- The sensitivity sets how loose the spotters are, how high the trained detector must score and how close the words must be.

**The trained detectors** (`hey_smokey.onnx` and `hey_tyrone.onnx`, 0.9 MB each, shipped with it) is built the [openWakeWord](https://github.com/dscripka/openWakeWord) way: a mel spectrogram and Google's speech embedding model (`melspectrogram.onnx`, `embedding_model.onnx`, both frozen, downloaded at setup from openWakeWord's v0.5.1 release rather than kept here), then a small network per name, each trained here on about 20,000 synthetic "hey Smokey"s or "hey Tyrone"s (1,000+ voices from Piper and Kokoro, in made-up rooms, over noise and music, at Bluetooth quality) against 95 hours of LibriSpeech audiobook speech (CC BY 4.0) and 12,000 near misses. On 4.7 hours of held-out speech it scores high about once an hour on its own, which is why it never opens without the check. It's what lifts "across a room, with music" from 60% to 78%. Every 80 ms it costs a few milliseconds of CPU.

Earlier versions:
- **6.0 to 6.4** used the keyword spotter alone. Good up close, but it missed most of the time across a room or over music.
- **5.x** compared the microphone's sound with recordings of your voice. That couldn't cope with distance, music or a Bluetooth mic.
- **Up to 4.x** used Windows' speech recognizers. They were inaccurate with a headset and, in the background, stopped hearing after the first call.

## Why not an exe

1.0.0 and 1.1.0 were a small unsigned tray exe. Windows Defender flagged a downloaded copy (`Behavior:Win32/Persistence.A!ml`, then `Trojan:Win32/Wacatac.H!ml`), as it often does with new unsigned programs that use the microphone. The script does the same job inside Windows' own signed PowerShell, with the engine in Python. The exe source (`WakeListener.cs`, `build.ps1`) is kept for when it can be code-signed.

## Claude relay (ClaudeRelay.ps1)

Connects Smokey to your Claude Code threads. Run it on the PC where the Claude desktop app runs your threads, which may not be the PC with the wake listener (for example a desktop you reach over Remote Desktop). Download: the `relay-v…` release (ClaudeRelay.zip), not the wake listener's.

**What's going on.** Every two minutes it reads the desktop app's session files on that PC and sends Project Check-in the list: each thread's name, folder, whether it's working, waiting on you or done, its last report and what it needs from you.

**Jobs: the Smokey thread (3.0).** Every Claude Code job you ask Smokey to send goes to one Claude Code thread on the PC, the Smokey thread. Smokey reads each job back and sends it only after you say yes. On the PC:

- The Smokey thread is one Claude Code session in its own folder (`%LOCALAPPDATA%\ClaudeRelay\tyrone`, the folder it was first made in, kept so the thread carries on; `smokey` on a new install), outside your projects. Each job picks the same session up again (`--resume`), one job at a time, so it remembers the jobs before it. `-Doctor` shows its session.
- It only dispatches, so every change goes on a branch (3.1): even a one-line change goes to a subthread. A job with separate parts gets one subthread per part: it writes a small file into `%LOCALAPPDATA%\ClaudeRelay\spawn` and the relay starts each one, up to 5 at once (more wait their turn). It can stop one it doesn't need with a `stop-<id>.json` file there.
- Each subthread runs in its own git worktree of one project (`<project>\.claude\worktrees\smokey-<id>`; `tyrone-<id>` for ones made before 4.3, with a junction to the project's own `node_modules` since 3.5, so checks that name a package by path work there too; the junction is removed before the worktree), on its own branch (`tyrone/<name>-<id>`). Since 3.2 it runs the project's checks (typecheck, unit tests, lint) and commits on its branch when they pass: it may run `npm run test/typecheck/lint/check`, `npm test`, `npx tsc/vitest/eslint`, `npx playwright test`, `node --check`, `pytest`, and `git status/diff/log/show/add/commit`, and nothing else (never push, merge, switch branches, deploy or delete). When it finishes, the relay commits anything it left uncommitted (marked so), removes the worktree and keeps the branch (or deletes it if nothing changed). Its result names the branch, the number of commits and how the checks went. Nothing is merged into a main branch; that's yours to do, or to ask for. A project without git gets one subthread at a time.
- Going live (3.3): in project-checkin, a subthread that committed with its checks passing goes live on its own. The relay itself does it, not Claude (subthreads still can't push): in a fresh copy of `origin/main` it merges the branch and `origin/dev`, runs `npm run typecheck` and `npm test` on the merged code, pushes to `main` and `dev`, starts `ltg-dev-deploy` on the devbox and waits until the new commit shows as live. One at a time per project. Your Smokey chat is told when it starts and how it ended (live with the commit, or why not: a clash, a failed check, a refused push), and Talk shows each step meanwhile. If anything fails, nothing is pushed and the work stays on its branch. Other projects stay on their branch until they get go-live steps (`$GoLive` in the script).
- Merged by hand (4.1): every two minutes the relay also checks each `smokey/` branch (`tyrone/` for ones made before 4.4.1) against GitHub and the devbox. A branch is **merged** when its last commit is in `origin/main`'s history, or **copied** when a commit on main names its last commit or the branch (as hand-merged copies do: "... from 3c991fc"), or has the same changes commit for commit. One on main is checked against the deploy branch and the commit `ltg-dev-deploy status` says is live. A subthread that didn't go live on its own gets a `merged.json` (merged, or live with the deploy commit), so Smokey's job list and your chat say it's merged, then live on dev, instead of "didn't go live"; a build merged by hand can be undone like any live one. The whole branch list goes with the live report, so Smokey can say which branches are merged into main and which aren't. `-Branches` runs the check once and prints it.
- Copies and dropped jobs (4.2): a commit on main with the branch's last commit message, word for word, also counts as a copy. A job that couldn't go live whose branch was later deleted (here and on GitHub) without reaching main gets a `merged.json` saying it was **dropped**, so Smokey stops saying it's still on that branch.
- Dropping a build (4.4): when you drop a build that hasn't finished (the **Drop build** button on the features list, or asking Smokey), the relay stops its Claude Code run, removes its copy (work it hadn't committed is discarded), keeps its branch if it made commits of its own and deletes it if not, frees its place, and stops reporting it. Nothing is sent to the chat, and it isn't tried again. A relay before 4.4 can't drop one: the app still clears it from the list quietly, and that relay parks it after a day.
- Only your project folders: folders where a Claude Code thread has run in the last 30 days (never the app's scratch or temp folders).
- Everything runs in the background with this PC's Claude Code (the copy the desktop app keeps), with file edits allowed and any command your project hasn't already allowed refused (`--permission-mode acceptEdits`). 45 minutes at most for each. Cancelling a job on Project Check-in stops it.
- Live: while anything runs, every few seconds it sends what the Smokey thread and each subthread are doing, step by step ("Reading talk-chat.tsx", "Editing actions.ts", "Running: npm test"), and Talk shows it as it happens. Results go back to Smokey and your Smokey chat (each subthread's too), and by phone if you asked for a call back.

Setup:

1. `powershell -ExecutionPolicy Bypass -File ClaudeRelay.ps1 -Connect`, then press **Connect Claude relay** on the page that opens. The key is kept encrypted for your Windows account in `%LOCALAPPDATA%\ClaudeRelay`.
2. `powershell -ExecutionPolicy Bypass -File ClaudeRelay.ps1 -Doctor`. The desktop app signs in only its own threads, so the first time it shows one command to sign Claude Code in for jobs (`claude.exe auth login`, which opens your browser). Run that once yourself.
3. `powershell -ExecutionPolicy Bypass -File ClaudeRelay.ps1 -Install` copies it to `%LOCALAPPDATA%\ClaudeRelay` and starts it hidden at every sign-in (a scheduled task named Claude relay). Run it again after downloading a new version.

`-DryRun` shows what it would send; `-Once` sends the thread list once; `-Uninstall` removes the scheduled task. Its log is `%LOCALAPPDATA%\ClaudeRelay\relay.log`, and each job's and subthread's prompt and output are kept for a week in `%LOCALAPPDATA%\ClaudeRelay\jobs` and `\subthreads`. Revoke the key on Project Check-in's Datalink page.

Tested on 2026-11-26: Tyrone sent a Claude Code job through the relay to this PC.


## Thread driver (ThreadDriver.ps1)

Lets Smokey type into your real Claude Code threads. Say "tell the project-checkin fork thread to run the tests again": Smokey reads it back, and on your yes the Thread driver on your PC opens that thread in the Claude desktop app, types the message into its box and presses Enter, exactly as if you'd typed it. The thread works with its own settings (and shows in the app, and on your phone through Remote Control). When it finishes its turn, its answer goes back to Smokey and your chat.

It needs the Claude relay connected (it uses the relay's key) and a live screen: it waits, and Smokey says why, while the PC is locked or Remote Desktop to it is disconnected, while the thread is busy, or while there's unsent text in that thread's box (it never overwrites it). It brings the Claude app to the front while it types. It types only after the app is really in front, checks the whole message landed before pressing Enter, and never clicks anything else: it never answers a permission prompt. When a thread stops to ask, Smokey tells you, and you approve it yourself.

1. Connect the Claude relay first (above).
2. `powershell -ExecutionPolicy Bypass -File ThreadDriver.ps1 -Doctor` checks it can see the Claude app, its message box and the relay's key.
3. `powershell -ExecutionPolicy Bypass -File ThreadDriver.ps1 -Install` copies it to `%LOCALAPPDATA%\ThreadDriver` and starts it hidden at every sign-in (a scheduled task named Thread driver).

`-Type <thread id> "message"` types one message now and waits for the answer (a test). `-Uninstall` removes the scheduled task. Its log is `%LOCALAPPDATA%\ThreadDriver\driver.log`.
