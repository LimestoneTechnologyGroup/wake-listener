// Wake listener: a tray app that listens (on this PC, offline) for a wake
// phrase such as "hey assistant" and opens the assistant's voice page, which
// starts the conversation by itself. No audio leaves the computer: Windows'
// built-in speech recognizer does the listening. Settings are in
// wake-listener.ini beside the exe.
//
// Built with the C# compiler that ships with Windows (.NET Framework 4), so
// C# 5: no string interpolation or expression-bodied members.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Speech.Recognition;
using System.Threading;
using System.Windows.Forms;

static class Program
{
    public static readonly string InstallDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WakeListener");
    public static readonly string InstalledExe = Path.Combine(InstallDir, "WakeListener.exe");
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    /// <summary>Starts with Windows (the current user's Run key), or not.</summary>
    public static void SetStartup(bool on)
    {
        using (var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(RunKey))
        {
            if (on) key.SetValue("WakeListener", "\"" + InstalledExe + "\"");
            else key.DeleteValue("WakeListener", false);
        }
    }

    public static bool StartsWithWindows()
    {
        using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey))
            return key != null && key.GetValue("WakeListener") != null;
    }

    [STAThread]
    static void Main(string[] args)
    {
        var here = Path.GetFullPath(Application.ExecutablePath);
        // Run from a download: install into the user's own folder (no admin), start with Windows, and run from there.
        if (!args.Contains("--test") && !string.Equals(here, InstalledExe, StringComparison.OrdinalIgnoreCase))
        {
            try
            {
                Directory.CreateDirectory(InstallDir);
                foreach (var old in Process.GetProcessesByName("WakeListener"))
                {
                    if (old.Id == Process.GetCurrentProcess().Id) continue;
                    try { old.Kill(); old.WaitForExit(3000); } catch { }
                }
                File.Copy(here, InstalledExe, true);
                SetStartup(true);
                Process.Start(new ProcessStartInfo(InstalledExe, "--welcome") { WorkingDirectory = InstallDir });
            }
            catch (Exception ex)
            {
                MessageBox.Show("The wake listener couldn't install itself: " + ex.Message, "Wake listener", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            return;
        }
        bool created;
        using (var one = new Mutex(true, "Local\\LimestoneWakeListener", out created))
        {
            if (!created) return; // Already running.
            Application.EnableVisualStyles();
            var settings = Settings.Load();
            if (args.Contains("--test"))
            {
                Environment.ExitCode = Listener.SelfTest(settings) ? 0 : 1;
                return;
            }
            Application.Run(new TrayApp(settings, args.Contains("--welcome")));
        }
    }
}

class Settings
{
    public string[] Phrases = new[] { "hey assistant" };
    public string Url = "https://project-checkin.dev.limestonetg.com/assistant?start=voice";
    public string Browser = "edge-app";
    public float Confidence = 0.7f;
    public int CooldownSeconds = 45;
    public static readonly string Folder = AppDomain.CurrentDomain.BaseDirectory;
    public static readonly string LogFile = Path.Combine(Folder, "wake-listener.log");

    public static Settings Load()
    {
        var s = new Settings();
        var path = Path.Combine(Folder, "wake-listener.ini");
        if (!File.Exists(path))
        {
            try { File.WriteAllText(path, DefaultIni); } catch { }
            return s;
        }
        foreach (var raw in File.ReadAllLines(path))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("#")) continue;
            var eq = line.IndexOf('=');
            if (eq < 1) continue;
            var key = line.Substring(0, eq).Trim().ToLowerInvariant();
            var value = line.Substring(eq + 1).Trim();
            if (key == "phrases")
            {
                var list = value.Split('|').Select(p => p.Trim().ToLowerInvariant()).Where(p => p.Length > 0).ToArray();
                if (list.Length > 0) s.Phrases = list;
            }
            else if (key == "url" && value.StartsWith("https://")) s.Url = value;
            else if (key == "browser") s.Browser = value.ToLowerInvariant();
            else if (key == "confidence") { float c; if (float.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out c) && c > 0 && c < 1) s.Confidence = c; }
            else if (key == "cooldown") { int n; if (int.TryParse(value, out n) && n >= 5) s.CooldownSeconds = n; }
        }
        return s;
    }

    const string DefaultIni =
        "# Wake listener settings. After a change: right-click the tray icon, Quit,\r\n" +
        "# then start Wake listener again (or sign out and back in).\r\n\r\n" +
        "# What to say, lowercase. Several are separated by |.\r\n" +
        "phrases=hey assistant|okay assistant\r\n\r\n" +
        "# The page it opens: the assistant, starting the voice straight away.\r\n" +
        "url=https://project-checkin.dev.limestonetg.com/assistant?start=voice\r\n\r\n" +
        "# edge-app or chrome-app (a clean app window, best for starting by itself),\r\n" +
        "# or default (a tab in your default browser).\r\n" +
        "browser=edge-app\r\n\r\n" +
        "# How sure Windows must be that it heard the phrase, 0.1 to 0.99.\r\n" +
        "# Raise it if it opens by mistake; lower it if it misses you.\r\n" +
        "confidence=0.7\r\n\r\n" +
        "# Seconds to ignore the phrase after opening, so it doesn't open twice.\r\n" +
        "cooldown=45\r\n";

    public static void Log(string message)
    {
        try
        {
            if (File.Exists(LogFile) && new FileInfo(LogFile).Length > 512 * 1024) File.Delete(LogFile);
            File.AppendAllText(LogFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + message + Environment.NewLine);
        }
        catch { }
    }
}

/// <summary>Listens for the wake phrases; raises Heard (on a thread-pool thread) with the phrase and confidence.</summary>
class Listener : IDisposable
{
    readonly SpeechRecognitionEngine engine;
    readonly Settings settings;
    public event Action<string, float> Heard;

    public Listener(Settings settings)
    {
        this.settings = settings;
        var culture = SpeechRecognitionEngine.InstalledRecognizers().Select(r => r.Culture).FirstOrDefault(c => c.Name == "en-US")
            ?? SpeechRecognitionEngine.InstalledRecognizers().Select(r => r.Culture).First();
        engine = new SpeechRecognitionEngine(culture);
        var wake = new Grammar(new GrammarBuilder(new Choices(settings.Phrases)) { Culture = culture }) { Name = "wake" };
        engine.LoadGrammar(wake);
        // Free dictation beside the wake phrases: ordinary talk matches dictation
        // instead of being forced onto the nearest wake phrase (fewer false starts).
        engine.LoadGrammar(new DictationGrammar { Name = "other" });
        var heardSomething = false;
        engine.SpeechDetected += (sender, e) => { if (!heardSomething) { heardSomething = true; Settings.Log("Hearing the microphone."); } };
        engine.SpeechRecognized += (sender, e) =>
        {
            if (e.Result.Grammar == null || e.Result.Grammar.Name != "wake") return;
            var handler = Heard;
            if (handler != null) handler(e.Result.Text, e.Result.Confidence);
        };
    }

    MicStream mic;

    /// <summary>
    /// Listens on Windows' default recording device. The audio is read here and
    /// handed to the recognizer, because Windows' speech engine only knows a
    /// default microphone once Speech Recognition setup has been run.
    /// </summary>
    public void Start()
    {
        mic = new MicStream();
        engine.SetInputToAudioStream(mic, new System.Speech.AudioFormat.SpeechAudioFormatInfo(MicStream.Rate, System.Speech.AudioFormat.AudioBitsPerSample.Sixteen, System.Speech.AudioFormat.AudioChannel.Mono));
        engine.RecognizeAsync(RecognizeMode.Multiple);
    }
    public void Stop() { try { engine.RecognizeAsyncCancel(); } catch { } if (mic != null) mic.Close(); }
    public void Dispose() { engine.Dispose(); if (mic != null) mic.Dispose(); }

    /// <summary>Feeds the phrases in as text (no microphone): checks the grammar matches them and ignores other words.</summary>
    public static bool SelfTest(Settings settings)
    {
        using (var l = new Listener(settings))
        {
            l.engine.SetInputToNull();
            var ok = true;
            foreach (var phrase in settings.Phrases)
            {
                var r = l.engine.EmulateRecognize(phrase);
                var hit = r != null && r.Grammar != null && r.Grammar.Name == "wake";
                Settings.Log("Self-test: " + (hit ? "match    " : "NO MATCH ") + phrase);
                ok &= hit;
            }
            var other = l.engine.EmulateRecognize("send the budget to finance");
            var miss = other == null || other.Grammar == null || other.Grammar.Name != "wake";
            Settings.Log("Self-test: " + (miss ? "ignored  " : "MATCHED  ") + "send the budget to finance");
            return ok && miss;
        }
    }
}

class TrayApp : ApplicationContext
{
    readonly Settings settings;
    readonly NotifyIcon tray;
    readonly MenuItem pauseItem;
    readonly SynchronizationContext ui;
    Listener listener;
    bool paused;
    DateTime last = DateTime.MinValue;

    public TrayApp(Settings settings, bool welcome)
    {
        this.settings = settings;
        ui = new WindowsFormsSynchronizationContext();
        var said = "\"" + settings.Phrases[0] + "\"";
        pauseItem = new MenuItem("Pause listening", (s, e) => TogglePause());
        var startupItem = new MenuItem("Start with Windows") { Checked = Program.StartsWithWindows() };
        startupItem.Click += (s, e) => { Program.SetStartup(!startupItem.Checked); startupItem.Checked = Program.StartsWithWindows(); };
        tray = new NotifyIcon
        {
            Icon = SystemIcons.Information,
            Text = Trim("Listening for " + said),
            Visible = true,
            ContextMenu = new ContextMenu(new[]
            {
                new MenuItem("Listening for " + said) { Enabled = false },
                new MenuItem("Open the assistant now", (s, e) => Open("menu")),
                pauseItem,
                new MenuItem("-"),
                new MenuItem("Open settings", (s, e) => OpenFile(Path.Combine(Settings.Folder, "wake-listener.ini"))),
                new MenuItem("Open log", (s, e) => OpenFile(Settings.LogFile)),
                startupItem,
                new MenuItem("Quit", (s, e) => Quit()),
            }),
        };
        tray.DoubleClick += (s, e) => Open("double-click");
        try
        {
            listener = new Listener(settings);
            listener.Heard += (phrase, confidence) => ui.Post(_ => OnHeard(phrase, confidence), null);
            listener.Start();
            Settings.Log("Started. Listening for " + string.Join(", ", settings.Phrases) + " (confidence " + settings.Confidence + ").");
            if (welcome) tray.ShowBalloonTip(8000, "Wake listener is on", "Say " + said + " and your assistant opens. It starts with Windows; right-click this icon to pause it or change settings.", ToolTipIcon.Info);
        }
        catch (Exception ex)
        {
            Settings.Log("Couldn't start listening: " + ex.Message);
            tray.Text = "Not listening: no microphone?";
            tray.ShowBalloonTip(8000, "Wake listener", "Couldn't start listening: " + ex.Message, ToolTipIcon.Warning);
        }
    }

    static string Trim(string s) { return s.Length > 63 ? s.Substring(0, 63) : s; }

    void OnHeard(string phrase, float confidence)
    {
        var line = "Heard \"" + phrase + "\" (confidence " + confidence.ToString("0.00", CultureInfo.InvariantCulture) + ")";
        if (paused) { Settings.Log(line + ": paused, ignored."); return; }
        if (confidence < settings.Confidence) { Settings.Log(line + ": too unsure, ignored."); return; }
        if ((DateTime.Now - last).TotalSeconds < settings.CooldownSeconds) { Settings.Log(line + ": just opened, ignored."); return; }
        Settings.Log(line + ": opening the assistant.");
        Open("wake word");
    }

    void Open(string why)
    {
        last = DateTime.Now;
        try
        {
            var edge = FindExe(@"Microsoft\Edge\Application\msedge.exe");
            var chrome = FindExe(@"Google\Chrome\Application\chrome.exe");
            // An app-style window: no tabs or address bar, and browsers let it start talking straight away.
            if (settings.Browser == "edge-app" && edge != null) Process.Start(edge, "--app=\"" + settings.Url + "\"");
            else if (settings.Browser == "chrome-app" && chrome != null) Process.Start(chrome, "--app=\"" + settings.Url + "\"");
            else Process.Start(new ProcessStartInfo(settings.Url) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Settings.Log("Couldn't open the assistant (" + why + "): " + ex.Message);
        }
    }

    static string FindExe(string relative)
    {
        foreach (var root in new[] { Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) })
        {
            if (string.IsNullOrEmpty(root)) continue;
            var path = Path.Combine(root, relative);
            if (File.Exists(path)) return path;
        }
        return null;
    }

    static void OpenFile(string path)
    {
        try { if (!File.Exists(path)) File.WriteAllText(path, ""); Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); } catch { }
    }

    void TogglePause()
    {
        paused = !paused;
        pauseItem.Text = paused ? "Resume listening" : "Pause listening";
        tray.Text = Trim(paused ? "Paused" : "Listening for \"" + settings.Phrases[0] + "\"");
        Settings.Log(paused ? "Paused." : "Resumed.");
    }

    void Quit()
    {
        Settings.Log("Quit.");
        tray.Visible = false;
        if (listener != null) { try { listener.Stop(); } catch { } listener.Dispose(); }
        ExitThread();
    }
}

/// <summary>
/// The default microphone as a never-ending stream of 16 kHz, 16-bit mono
/// audio (Windows' waveIn, on the "default device" mapper). Read blocks until
/// audio arrives, as the speech recognizer expects of a live source.
/// </summary>
class MicStream : Stream
{
    public const int Rate = 16000;
    const int BufferBytes = Rate * 2 / 10; // 100 ms
    const int Buffers = 8;
    const uint WAVE_MAPPER = 0xFFFFFFFF;
    const uint CALLBACK_EVENT = 0x50000;
    const uint WHDR_DONE = 1;

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    struct WaveFormat { public ushort wFormatTag, nChannels; public uint nSamplesPerSec, nAvgBytesPerSec; public ushort nBlockAlign, wBitsPerSample, cbSize; }

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    struct WaveHdr { public IntPtr lpData; public uint dwBufferLength, dwBytesRecorded; public IntPtr dwUser; public uint dwFlags, dwLoops; public IntPtr lpNext, reserved; }

    [System.Runtime.InteropServices.DllImport("winmm.dll")] static extern int waveInOpen(out IntPtr h, uint device, ref WaveFormat format, IntPtr callback, IntPtr instance, uint flags);
    [System.Runtime.InteropServices.DllImport("winmm.dll")] static extern int waveInPrepareHeader(IntPtr h, IntPtr hdr, int size);
    [System.Runtime.InteropServices.DllImport("winmm.dll")] static extern int waveInUnprepareHeader(IntPtr h, IntPtr hdr, int size);
    [System.Runtime.InteropServices.DllImport("winmm.dll")] static extern int waveInAddBuffer(IntPtr h, IntPtr hdr, int size);
    [System.Runtime.InteropServices.DllImport("winmm.dll")] static extern int waveInStart(IntPtr h);
    [System.Runtime.InteropServices.DllImport("winmm.dll")] static extern int waveInReset(IntPtr h);
    [System.Runtime.InteropServices.DllImport("winmm.dll")] static extern int waveInClose(IntPtr h);

    static readonly int HdrSize = System.Runtime.InteropServices.Marshal.SizeOf(typeof(WaveHdr));
    readonly IntPtr device;
    readonly IntPtr[] headers = new IntPtr[Buffers];
    readonly AutoResetEvent signal = new AutoResetEvent(false);
    readonly Queue<byte[]> ready = new Queue<byte[]>();
    readonly object gate = new object();
    readonly Thread pump;
    byte[] current; int offset;
    volatile bool closed;

    public MicStream()
    {
        var format = new WaveFormat { wFormatTag = 1, nChannels = 1, nSamplesPerSec = Rate, wBitsPerSample = 16, nBlockAlign = 2, nAvgBytesPerSec = Rate * 2 };
        var result = waveInOpen(out device, WAVE_MAPPER, ref format, signal.SafeWaitHandle.DangerousGetHandle(), IntPtr.Zero, CALLBACK_EVENT);
        if (result != 0) throw new IOException("The microphone couldn't be opened (waveIn error " + result + "). Check a microphone is plugged in and set as the default recording device.");
        for (var i = 0; i < Buffers; i++)
        {
            var hdr = new WaveHdr { lpData = System.Runtime.InteropServices.Marshal.AllocHGlobal(BufferBytes), dwBufferLength = BufferBytes };
            headers[i] = System.Runtime.InteropServices.Marshal.AllocHGlobal(HdrSize);
            System.Runtime.InteropServices.Marshal.StructureToPtr(hdr, headers[i], false);
            waveInPrepareHeader(device, headers[i], HdrSize);
            waveInAddBuffer(device, headers[i], HdrSize);
        }
        pump = new Thread(Pump) { IsBackground = true, Name = "Microphone" };
        pump.Start();
        waveInStart(device);
    }

    // Collects each filled buffer, queues a copy for Read, and hands the buffer back to Windows.
    void Pump()
    {
        while (!closed)
        {
            signal.WaitOne(500);
            for (var i = 0; i < Buffers && !closed; i++)
            {
                var hdr = (WaveHdr)System.Runtime.InteropServices.Marshal.PtrToStructure(headers[i], typeof(WaveHdr));
                if ((hdr.dwFlags & WHDR_DONE) == 0) continue;
                if (hdr.dwBytesRecorded > 0)
                {
                    var data = new byte[hdr.dwBytesRecorded];
                    System.Runtime.InteropServices.Marshal.Copy(hdr.lpData, data, 0, data.Length);
                    lock (gate) { ready.Enqueue(data); if (ready.Count > 300) ready.Dequeue(); Monitor.PulseAll(gate); }
                }
                waveInUnprepareHeader(device, headers[i], HdrSize);
                hdr.dwFlags = 0; hdr.dwBytesRecorded = 0;
                System.Runtime.InteropServices.Marshal.StructureToPtr(hdr, headers[i], false);
                waveInPrepareHeader(device, headers[i], HdrSize);
                waveInAddBuffer(device, headers[i], HdrSize);
            }
        }
    }

    public override int Read(byte[] buffer, int start, int count)
    {
        var copied = 0;
        while (copied < count)
        {
            if (current == null || offset >= current.Length)
            {
                lock (gate)
                {
                    while (ready.Count == 0 && !closed) Monitor.Wait(gate, 500);
                    if (ready.Count == 0) return copied; // Closed.
                    current = ready.Dequeue(); offset = 0;
                }
            }
            var n = Math.Min(count - copied, current.Length - offset);
            Buffer.BlockCopy(current, offset, buffer, start + copied, n);
            offset += n; copied += n;
        }
        return copied;
    }

    public override void Close()
    {
        if (closed) return;
        closed = true;
        lock (gate) Monitor.PulseAll(gate);
        waveInReset(device);
        if (pump != null) pump.Join(1000);
        for (var i = 0; i < Buffers; i++)
        {
            if (headers[i] == IntPtr.Zero) continue;
            waveInUnprepareHeader(device, headers[i], HdrSize);
            var hdr = (WaveHdr)System.Runtime.InteropServices.Marshal.PtrToStructure(headers[i], typeof(WaveHdr));
            System.Runtime.InteropServices.Marshal.FreeHGlobal(hdr.lpData);
            System.Runtime.InteropServices.Marshal.FreeHGlobal(headers[i]);
            headers[i] = IntPtr.Zero;
        }
        waveInClose(device);
        base.Close();
    }

    public override bool CanRead { get { return true; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return false; } }
    public override long Length { get { throw new NotSupportedException(); } }
    public override long Position { get { return 0; } set { } }
    public override void Flush() { }
    public override long Seek(long o, SeekOrigin s) { throw new NotSupportedException(); }
    public override void SetLength(long v) { throw new NotSupportedException(); }
    public override void Write(byte[] b, int o, int c) { throw new NotSupportedException(); }
}
