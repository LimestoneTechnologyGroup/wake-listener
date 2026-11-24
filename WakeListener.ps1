# Wake listener: say "hey Tyrone" and your Project Check-in assistant opens.
#
# Plain PowerShell, no exe. Windows' built-in speech recognizer listens for a
# short list of phrases on your default microphone, on this PC, whatever window
# is in front: nothing is recorded or sent anywhere. When it hears the phrase,
# it opens the assistant's voice page, which starts talking.
#
# The window shows what's going on: which microphone, a live level meter
# (Windows' own meter for that microphone), and everything it hears and why it
# did or didn't open. It follows you if you change your default microphone.
#
# Run it: double-click "Start wake listener.cmd" (or right-click this file >
# Run with PowerShell). Close the window to stop.
# Check it without a microphone: WakeListener.ps1 -Test

param([switch]$Test)

$Version = "4.0.1"

# ---- Settings ---------------------------------------------------------------
$Phrases       = @("hey tyrone", "okay tyrone", "hi tyrone", "ok tyrone")   # what to say, lowercase
$Url           = "https://project-checkin.dev.limestonetg.com/assistant?start=voice&close=1"   # close=1: the window closes itself once the conversation is saved
$Browser       = "edge-app"   # edge-app, chrome-app, or default
# How sure it must be: High, Medium or Low. Low opens on anything it didn't
# reject; raise it to Medium if it ever opens by mistake.
$MinVerdict    = "Low"
# Close enough: what the recognizer often writes down instead ("hey tyron",
# "a tyrone"), when said on their own.
$CloseEnough   = '^(?:(?:hey|hay|hi|high|okay|ok|a|eh)\s+)?(?:tyrone|tyron|tyrones|tyrone''s|ty rone)$'
# While the assistant's window is open, the phrase is ignored (so it never opens
# twice); it's found by its title. Also ignored for a few seconds after opening,
# while the page loads and has no title yet.
$AssistantTitle = "Assistant ·"
$GraceSecs     = 15
# -----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

# The listening engine: Windows' classic speech recognizer (System.Speech), which
# keeps listening whatever window is in front (Windows' newer recognizer only
# hears a desktop program while its window has the focus). It's fed straight
# from the Windows default microphone, the same one the level meter reads.
# Results go into a queue this script reads: "result|verdict|score|words" and
# "completed|why". C# because the recognizer reports from its own threads.
Add-Type -AssemblyName System.Speech
Add-Type -ReferencedAssemblies System.Speech -Language CSharp @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Speech.AudioFormat;
using System.Speech.Recognition;
using System.Text.RegularExpressions;
using System.Threading;

namespace WakeListenerSpeech {
  public static class Continuous {
    public static readonly ConcurrentQueue<string> Heard = new ConcurrentQueue<string>();
    static SpeechRecognitionEngine engine;
    static MicStream mic;
    static Regex closeEnough;

    static SpeechRecognitionEngine Build(string[] phrases, string closeEnoughPattern) {
      var culture = SpeechRecognitionEngine.InstalledRecognizers().Select(r => r.Culture).FirstOrDefault(c => c.Name == "en-US")
        ?? SpeechRecognitionEngine.InstalledRecognizers().Select(r => r.Culture).First();
      var e = new SpeechRecognitionEngine(culture);
      e.LoadGrammar(new Grammar(new GrammarBuilder(new Choices(phrases)) { Culture = culture }) { Name = "wake" });
      // Free dictation beside the phrases: ordinary talk lands there instead of
      // being forced onto the nearest phrase, so it opens by mistake less often.
      e.LoadGrammar(new DictationGrammar { Name = "other" });
      closeEnough = new Regex(closeEnoughPattern, RegexOptions.IgnoreCase);
      e.SpeechRecognized += (s, a) => Report(a.Result, false);
      e.SpeechRecognitionRejected += (s, a) => Report(a.Result, true);
      e.RecognizeCompleted += (s, a) => Heard.Enqueue("completed|" + (a.Error != null ? "Error: " + a.Error.Message : a.Cancelled ? "UserCanceled" : "Success"));
      return e;
    }

    static string Verdict(float c) { return c >= 0.75f ? "High" : c >= 0.5f ? "Medium" : c >= 0.2f ? "Low" : "Rejected"; }
    static string Score(float c) { return c.ToString("0.00", CultureInfo.InvariantCulture); }
    static string Words(string t) { return Regex.Replace(Regex.Replace((t ?? "").ToLowerInvariant(), "[^a-z' ]", " "), "\\s+", " ").Trim(); }

    /// <summary>The phrase (or something close enough), in its best guess or any second guess.</summary>
    static string Judge(RecognitionResult r, bool rejected) {
      if (r == null) return "result|Rejected|0|";
      var guesses = new List<RecognizedPhrase> { r };
      try { guesses.AddRange(r.Alternates); } catch { }
      foreach (var g in guesses) {
        if (g == null) continue;
        if (g.Grammar != null && g.Grammar.Name == "wake" && g.Confidence >= 0.2f) return "result|" + Verdict(g.Confidence) + "|" + Score(g.Confidence) + "|" + g.Text;
        if (closeEnough.IsMatch(Words(g.Text)) && g.Confidence >= 0.2f) return "result|Low|" + Score(g.Confidence) + "|" + g.Text;
      }
      return "result|Rejected|" + Score(r.Confidence) + "|";
    }
    static void Report(RecognitionResult r, bool rejected) { Heard.Enqueue(Judge(r, rejected)); }

    /// <summary>Starts listening on the default microphone. Throws why not.</summary>
    public static void Start(string[] phrases, string closeEnoughPattern) { Begin(phrases, closeEnoughPattern, false); }
    /// <summary>For the self-test: the same start-up, fed silence instead of a microphone.</summary>
    public static void StartSilent(string[] phrases, string closeEnoughPattern) { Begin(phrases, closeEnoughPattern, true); }
    static void Begin(string[] phrases, string closeEnoughPattern, bool silent) {
      Stop();
      engine = Build(phrases, closeEnoughPattern);
      mic = new MicStream(silent);
      engine.SetInputToAudioStream(mic, new SpeechAudioFormatInfo(MicStream.Rate, AudioBitsPerSample.Sixteen, AudioChannel.Mono));
      engine.RecognizeAsync(RecognizeMode.Multiple);
    }

    public static void Stop() {
      var e = engine; var m = mic; engine = null; mic = null;
      if (e != null) { try { e.RecognizeAsyncCancel(); } catch { } }
      if (m != null) { try { m.Close(); } catch { } }
      if (e != null) { try { e.Dispose(); } catch { } }
    }

    /// <summary>For the self-test: what it makes of these words, said on their own (no microphone).</summary>
    public static string Try(string[] phrases, string closeEnoughPattern, string words) {
      using (var e = Build(phrases, closeEnoughPattern)) {
        e.SetInputToNull();
        var r = e.EmulateRecognize(words);
        while (Heard.Count > 0) { string x; Heard.TryDequeue(out x); }
        return Judge(r, r == null);
      }
    }
  }

  /// <summary>
  /// The Windows default microphone as a live 16 kHz, 16-bit mono stream (waveIn
  /// on the default-device mapper). Read waits until sound arrives, as the
  /// recognizer expects of a live source.
  /// </summary>
  public class MicStream : Stream {
    public const int Rate = 16000;
    const int BufferBytes = Rate * 2 / 10;
    const int Buffers = 8;
    [StructLayout(LayoutKind.Sequential)] struct WaveFormat { public ushort wFormatTag, nChannels; public uint nSamplesPerSec, nAvgBytesPerSec; public ushort nBlockAlign, wBitsPerSample, cbSize; }
    [StructLayout(LayoutKind.Sequential)] struct WaveHdr { public IntPtr lpData; public uint dwBufferLength, dwBytesRecorded; public IntPtr dwUser; public uint dwFlags, dwLoops; public IntPtr lpNext, reserved; }
    [DllImport("winmm.dll")] static extern int waveInOpen(out IntPtr h, uint device, ref WaveFormat format, IntPtr callback, IntPtr instance, uint flags);
    [DllImport("winmm.dll")] static extern int waveInPrepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] static extern int waveInUnprepareHeader(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] static extern int waveInAddBuffer(IntPtr h, IntPtr hdr, int size);
    [DllImport("winmm.dll")] static extern int waveInStart(IntPtr h);
    [DllImport("winmm.dll")] static extern int waveInReset(IntPtr h);
    [DllImport("winmm.dll")] static extern int waveInClose(IntPtr h);
    static readonly int HdrSize = Marshal.SizeOf(typeof(WaveHdr));
    readonly IntPtr device;
    readonly IntPtr[] headers = new IntPtr[Buffers];
    readonly AutoResetEvent signal = new AutoResetEvent(false);
    readonly Queue<byte[]> ready = new Queue<byte[]>();
    readonly object gate = new object();
    readonly Thread pump;
    byte[] current; int offset;
    long position;
    volatile bool closed;
    readonly bool silent;

    public MicStream(bool silent) {
      this.silent = silent;
      if (silent) {
        // The self-test: 100 ms of silence every 100 ms, through the same Read the recognizer uses.
        pump = new Thread(() => { while (!closed) { Thread.Sleep(100); lock (gate) { ready.Enqueue(new byte[BufferBytes]); if (ready.Count > 300) ready.Dequeue(); Monitor.PulseAll(gate); } } }) { IsBackground = true, Name = "Silence" };
        pump.Start();
        return;
      }
      var format = new WaveFormat { wFormatTag = 1, nChannels = 1, nSamplesPerSec = Rate, wBitsPerSample = 16, nBlockAlign = 2, nAvgBytesPerSec = Rate * 2 };
      var result = waveInOpen(out device, 0xFFFFFFFF, ref format, signal.SafeWaitHandle.DangerousGetHandle(), IntPtr.Zero, 0x50000);
      if (result != 0) throw new IOException("The microphone couldn't be opened (waveIn error " + result + ").");
      for (var i = 0; i < Buffers; i++) {
        var hdr = new WaveHdr { lpData = Marshal.AllocHGlobal(BufferBytes), dwBufferLength = BufferBytes };
        headers[i] = Marshal.AllocHGlobal(HdrSize);
        Marshal.StructureToPtr(hdr, headers[i], false);
        waveInPrepareHeader(device, headers[i], HdrSize);
        waveInAddBuffer(device, headers[i], HdrSize);
      }
      pump = new Thread(Pump) { IsBackground = true, Name = "Microphone" };
      pump.Start();
      waveInStart(device);
    }

    void Pump() {
      while (!closed) {
        signal.WaitOne(500);
        for (var i = 0; i < Buffers && !closed; i++) {
          var hdr = (WaveHdr)Marshal.PtrToStructure(headers[i], typeof(WaveHdr));
          if ((hdr.dwFlags & 1) == 0) continue;
          if (hdr.dwBytesRecorded > 0) {
            var data = new byte[hdr.dwBytesRecorded];
            Marshal.Copy(hdr.lpData, data, 0, data.Length);
            lock (gate) { ready.Enqueue(data); if (ready.Count > 300) ready.Dequeue(); Monitor.PulseAll(gate); }
          }
          waveInUnprepareHeader(device, headers[i], HdrSize);
          hdr.dwFlags = 0; hdr.dwBytesRecorded = 0;
          Marshal.StructureToPtr(hdr, headers[i], false);
          waveInPrepareHeader(device, headers[i], HdrSize);
          waveInAddBuffer(device, headers[i], HdrSize);
        }
      }
    }

    public override int Read(byte[] buffer, int start, int count) {
      var copied = 0;
      while (copied < count) {
        if (current == null || offset >= current.Length) {
          lock (gate) {
            while (ready.Count == 0 && !closed) Monitor.Wait(gate, 500);
            if (ready.Count == 0) return copied;
            current = ready.Dequeue(); offset = 0;
          }
        }
        var n = Math.Min(count - copied, current.Length - offset);
        Buffer.BlockCopy(current, offset, buffer, start + copied, n);
        offset += n; copied += n;
      }
      position += copied;
      return copied;
    }

    public override void Close() {
      if (closed) return;
      closed = true;
      lock (gate) Monitor.PulseAll(gate);
      if (silent) { if (pump != null) pump.Join(1000); base.Close(); return; }
      waveInReset(device);
      if (pump != null) pump.Join(1000);
      for (var i = 0; i < Buffers; i++) {
        if (headers[i] == IntPtr.Zero) continue;
        waveInUnprepareHeader(device, headers[i], HdrSize);
        var hdr = (WaveHdr)Marshal.PtrToStructure(headers[i], typeof(WaveHdr));
        Marshal.FreeHGlobal(hdr.lpData);
        Marshal.FreeHGlobal(headers[i]);
        headers[i] = IntPtr.Zero;
      }
      waveInClose(device);
      base.Close();
    }

    public override bool CanRead { get { return true; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return false; } }
    // A live source has no end and can't be rewound. The recognizer asks anyway,
    // and gives up on "not supported", so answer like a never-ending stream.
    public override long Length { get { return -1; } }
    public override long Position { get { return position; } set { } }
    public override void Flush() { }
    public override long Seek(long o, SeekOrigin s) { return position; }
    public override void SetLength(long v) { }
    public override void Write(byte[] b, int o, int c) { }
  }
}
'@

# Windows' default recording device: its name and id, and its live level, from the Core Audio API.
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
  [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioMeterInformation { int GetPeakValue(out float peak); }
  [StructLayout(LayoutKind.Sequential)] struct PropertyKey { public Guid fmtid; public int pid; }
  [StructLayout(LayoutKind.Explicit)] struct PropVariant { [FieldOffset(0)] public short vt; [FieldOffset(8)] public IntPtr pointer; [FieldOffset(8)] public long padding; }
  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }
  public static class DefaultMicrophone {
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PropVariant value);
    static IMMDevice Device() {
      var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
      IMMDevice device;
      return enumerator.GetDefaultAudioEndpoint(1, 0, out device) == 0 ? device : null;
    }
    /// <summary>"id|name" of the default recording device, or "" when there is none.</summary>
    public static string Describe() {
      try {
        var device = Device();
        if (device == null) return "";
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
    static string meterId;
    static IAudioMeterInformation meter;
    /// <summary>The default microphone's live level, 0 to 100 (Windows' own meter), or -1 when there's none.</summary>
    public static int Level() {
      try {
        var device = Device();
        if (device == null) return -1;
        string id; device.GetId(out id);
        if (meter == null || id != meterId) {
          var iid = new Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064");
          object o;
          if (device.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) return -1;
          meter = (IAudioMeterInformation)o; meterId = id;
        }
        float peak; meter.GetPeakValue(out peak);
        return (int)Math.Round(Math.Min(1f, Math.Max(0f, peak)) * 100);
      } catch { meter = null; return -1; }
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

# Listening on and off. (The loop calls these: New-Recognizer, then Start-Session; Stop-Session.)
function New-Recognizer { return "classic" }
function Start-Session($r) { [WakeListenerSpeech.Continuous]::Start([string[]]$Phrases, $CloseEnough) }
function Stop-Session($r) { if ($r) { try { [WakeListenerSpeech.Continuous]::Stop() } catch { } } }

if ($Test) {
  $ok = $true
  $opens = $Phrases + @("hey tyron", "a tyrone", "hey tyrone's")
  $ignores = @("send the budget to finance", "tyrone called about the permit yesterday", "hey how are you", "turn on the lights")
  foreach ($p in $opens + $ignores) {
    $verdict = ([WakeListenerSpeech.Continuous]::Try([string[]]$Phrases, $CloseEnough, $p)).Split("|")[1]
    $hit = $verdict -ne "Rejected"
    $want = $opens -contains $p
    "{0,-9} {1}{2}" -f $(if ($hit) { "opens" } else { "ignored" }), $p, $(if ($hit -ne $want) { "   <-- WRONG" } else { "" })
    $ok = $ok -and ($hit -eq $want)
  }
  $mic = Get-Microphone
  "microphone: " + $(if ($mic) { $mic.Name + ", level " + [WakeListenerAudio.DefaultMicrophone]::Level() } else { "none on this PC" })
  # The real start-up path, fed silence (this is what failed in 4.0.0 on a PC with a mic).
  try {
    [WakeListenerSpeech.Continuous]::StartSilent([string[]]$Phrases, $CloseEnough)
    Start-Sleep -Seconds 3
    $item = $null; $problems = @(); while ([WakeListenerSpeech.Continuous]::Heard.TryDequeue([ref]$item)) { if ($item -like "completed|Error*") { $problems += $item } }
    [WakeListenerSpeech.Continuous]::Stop()
    if ($problems) { "listening on silence: FAILED " + ($problems -join "; "); $ok = $false } else { "listening on silence: ran 3 seconds, no errors" }
  } catch { $why = $_.Exception; while ($why.InnerException) { $why = $why.InnerException }; "listening on silence: FAILED " + $why.Message; $ok = $false }
  try { Start-Session "classic"; Start-Sleep -Seconds 2; Stop-Session "classic"; "listening: started and stopped" }
  catch { $why = $_.Exception; while ($why.InnerException) { $why = $why.InnerException }; "listening: " + $why.Message + $(if (-not $mic) { " (expected: no microphone here)" } else { "" }); if ($mic) { $ok = $false } }
  if ($ok) { exit 0 } else { exit 1 }
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
function Say([string]$text, [string]$color = "Gray") {
  Clear-Meter
  Write-Host ("{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $text) -ForegroundColor $color
  if ($color -eq "Yellow" -or $color -eq "Red") { Notify $text }
}
$script:loudest = 0
function Show-Meter {
  $level = [WakeListenerAudio.DefaultMicrophone]::Level()
  if ($level -gt $script:loudest) { $script:loudest = $level }
  if ($level -gt $script:windowLoudest) { $script:windowLoudest = $level }
  if ($level -gt $script:soundSinceEvent) { $script:soundSinceEvent = $level }
  $state = if ($level -lt 0) { "no microphone" } elseif ($level -ge 8) { "hearing sound" } else { "quiet" }
  $shown = [Math]::Max(0, $level)
  $bars = [Math]::Round($shown / 100 * 30)
  $line = "  Mic level [" + ("#" * $bars).PadRight(30, ".") + "] " + ("{0,3}" -f $shown) + "   " + $state
  [Console]::Write("`r" + $line.PadRight((Width)).Substring(0, (Width)))
  $script:meterShown = $true
}

# ---- The tray icon ----------------------------------------------------------
# It lives next to the clock and keeps listening whatever window is in front.
# The activity window (meter and log) starts hidden; the tray menu shows it.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace WakeListenerWindow -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int show);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
'@
# Is the assistant open? A visible Edge or Chrome window whose title contains $AssistantTitle.
Add-Type -Language CSharp @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
namespace WakeListenerWindows {
  public static class Browser {
    delegate bool EnumProc(IntPtr window, IntPtr param);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr param);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int max);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    public static bool HasWindow(string titlePart) {
      bool found = false;
      EnumWindows((w, p) => {
        if (!IsWindowVisible(w)) return true;
        var text = new StringBuilder(512);
        GetWindowText(w, text, text.Capacity);
        if (text.ToString().IndexOf(titlePart, StringComparison.OrdinalIgnoreCase) < 0) return true;
        uint pid; GetWindowThreadProcessId(w, out pid);
        try {
          var name = Process.GetProcessById((int)pid).ProcessName.ToLowerInvariant();
          if (name == "msedge" || name == "chrome") { found = true; return false; }
        } catch { }
        return true;
      }, IntPtr.Zero);
      return found;
    }
  }
}
'@
function Test-AssistantOpen { try { [WakeListenerWindows.Browser]::HasWindow($AssistantTitle) } catch { $false } }

$script:consoleWindow = [WakeListenerWindow.Native]::GetConsoleWindow()
$script:windowShown = $true
function Set-WindowShown([bool]$show) {
  $script:windowShown = $show
  [void][WakeListenerWindow.Native]::ShowWindow($script:consoleWindow, $(if ($show) { 9 } else { 0 }))
  if ($show) { [void][WakeListenerWindow.Native]::SetForegroundWindow($script:consoleWindow) }
  $script:showItem.Text = if ($show) { "Hide activity window" } else { "Show activity window" }
}
$script:paused = $false
$script:quit = $false
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Icon = [System.Drawing.SystemIcons]::Information
$script:tray.Visible = $true
$script:showItem = New-Object System.Windows.Forms.MenuItem("Show activity window")
$script:showItem.add_Click({ Set-WindowShown (-not $script:windowShown) })
$pauseItem = New-Object System.Windows.Forms.MenuItem("Pause listening")
$pauseItem.add_Click({ $script:paused = -not $script:paused; $this.Text = if ($script:paused) { "Resume listening" } else { "Pause listening" }; Say $(if ($script:paused) { "Paused: it won't open the assistant until you resume." } else { "Resumed." }); Set-TrayText })
$openItem = New-Object System.Windows.Forms.MenuItem("Open the assistant now")
$openItem.add_Click({ try { Open-Assistant } catch { } })
$quitItem = New-Object System.Windows.Forms.MenuItem("Quit (stop listening)")
$quitItem.add_Click({ $script:quit = $true })
$script:tray.ContextMenu = New-Object System.Windows.Forms.ContextMenu(,[System.Windows.Forms.MenuItem[]]@($script:showItem, $pauseItem, $openItem, (New-Object System.Windows.Forms.MenuItem("-")), $quitItem))
$script:tray.add_DoubleClick({ Set-WindowShown $true })
$script:lastHeard = ""
function Set-TrayText {
  $micName = if ($script:micName) { $script:micName } else { "no microphone" }
  $text = $(if ($script:paused) { "Wake listener: paused" } else { "Wake listener: listening" }) + "`n" + $micName + $(if ($script:lastHeard) { "`nLast: " + $script:lastHeard } else { "" })
  $script:tray.Text = if ($text.Length -gt 63) { $text.Substring(0, 63) } else { $text }
}
$script:lastBalloon = [datetime]::MinValue
function Notify([string]$text) {
  if ($script:windowShown -or ((Get-Date) - $script:lastBalloon).TotalSeconds -lt 60) { return }
  $script:lastBalloon = Get-Date
  $script:tray.ShowBalloonTip(8000, "Wake listener", $text, [System.Windows.Forms.ToolTipIcon]::Warning)
}
# Waits, keeping the tray menu responsive and the meter moving.
function Idle([int]$ms) { $until = (Get-Date).AddMilliseconds($ms); while ((Get-Date) -lt $until -and -not $script:quit) { [System.Windows.Forms.Application]::DoEvents(); Show-Meter; Start-Sleep -Milliseconds 100 } }

Clear-Host
Write-Host "Wake listener $Version" -ForegroundColor White
Write-Host ("Say " + (($Phrases | Select-Object -First 2 | ForEach-Object { "`"$_`"" }) -join " or ") + " and your assistant opens (when Windows' verdict is $MinVerdict or better).")
Write-Host "Opens: $Url"
Write-Host "This window hides itself: the tray icon by the clock keeps listening, whatever window is in front."
Write-Host "Right-click the tray icon to show this window again, pause, open the assistant, or quit."
Write-Host "(If you click inside this window it pauses until you press Esc.)"
Write-Host ""
Set-TrayText
Idle 2500
Set-WindowShown $false
$script:tray.ShowBalloonTip(6000, "Wake listener is on", "Say `"$($Phrases[0])`" and your assistant opens. It's listening in the tray; right-click the icon for options.", [System.Windows.Forms.ToolTipIcon]::Info)

$recognizer = $null
$mic = $null
$last = [datetime]::MinValue
$since = Get-Date
$quietWarned = $false
$rank = @{ High = 3; Medium = 2; Low = 1; Rejected = 0 }
$nextMicCheck = Get-Date
$restartAt = $null
# While the assistant is open it has the microphone: the listener steps back,
# and starts a fresh session when it closes (a Bluetooth mic's audio changes
# under a session that kept running through the call, leaving it deaf).
$handedOver = $false
$nextWindowCheck = Get-Date
# Watchdog: sound on the mic but no word from the speech engine for a minute means it's stuck.
$script:lastEventAt = Get-Date
$script:soundSinceEvent = 0

while (-not $script:quit) {
  # Every second: is the assistant open? Step back while it is; listen afresh when it closes.
  if ((Get-Date) -ge $nextWindowCheck) {
    $nextWindowCheck = (Get-Date).AddSeconds(1)
    $open = (Test-AssistantOpen) -or (((Get-Date) - $last).TotalSeconds -lt $GraceSecs)
    if ($open -and -not $handedOver) {
      $handedOver = $true
      Stop-Session $recognizer; $recognizer = $null
      Say "The assistant is open: not listening until it closes." DarkGray
      $script:lastHeard = "assistant open"; Set-TrayText
    } elseif (-not $open -and $handedOver) {
      $handedOver = $false
      Say "The assistant closed: listening again."
      $script:lastHeard = (Get-Date -Format "HH:mm") + " last call"; Set-TrayText
      $restartAt = Get-Date
    }
  }
  if ($handedOver) {
    $item = $null; while ([WakeListenerSpeech.Continuous]::Heard.TryDequeue([ref]$item)) { }
    [System.Windows.Forms.Application]::DoEvents(); Show-Meter; Start-Sleep -Milliseconds 100
    continue
  }

  # Every few seconds: follow the default microphone, (re)starting on it whenever it changes.
  if ((Get-Date) -ge $nextMicCheck -or ($restartAt -and (Get-Date) -ge $restartAt)) {
    $nextMicCheck = (Get-Date).AddSeconds(3)
    $now = Get-Microphone
    if (-not $now) {
      if ($mic -or -not $script:noMicSaid) { Say "No microphone found. Plug one in or set a default in Settings > System > Sound > Input. Checking every few seconds." Yellow; $script:noMicSaid = $true }
      Stop-Session $recognizer; $recognizer = $null; $mic = $null
      $script:micName = $null; Set-TrayText
    } else {
      $script:noMicSaid = $false
      if (-not $recognizer -or -not $mic -or $now.Id -ne $mic.Id -or $restartAt) {
        if ($mic -and $now.Id -ne $mic.Id) { Say "The default microphone changed." }
        Stop-Session $recognizer; $recognizer = $null
        $mic = $now; $restartAt = $null
        try {
          $recognizer = New-Recognizer
          Start-Session $recognizer
          Say ("Listening on: " + $mic.Name + " (continuously)") Green
          $script:micName = $mic.Name; Set-TrayText
          $host.UI.RawUI.WindowTitle = "Wake listener: listening on " + $mic.Name
          $since = Get-Date; $script:loudest = 0; $script:windowLoudest = 0; $quietWarned = $false
          $script:lastEventAt = Get-Date; $script:soundSinceEvent = 0
          $script:lastStartError = $null
        } catch {
          $why = $_.Exception; while ($why.InnerException) { $why = $why.InnerException }
          if ($why.HResult -eq -2147199735) { Say "Windows' speech privacy setting is blocking it: turn on Settings > Privacy & security > Speech > Online speech recognition. Trying again shortly." Yellow }
          elseif ($why.Message -ne $script:lastStartError) { Say ("Couldn't start listening: " + $why.Message + " Trying again every few seconds.") Red }
          $script:lastStartError = $why.Message
          Stop-Session $recognizer; $recognizer = $null
          $restartAt = (Get-Date).AddSeconds(5)
        }
      }
    }
  }

  # What it heard (and whether listening stopped), from the helper's queue.
  $item = $null
  while ([WakeListenerSpeech.Continuous]::Heard.TryDequeue([ref]$item)) {
    $script:lastEventAt = Get-Date; $script:soundSinceEvent = 0
    $parts = $item.Split("|", 4)
    if ($parts[0] -eq "completed") {
      # Listening stopped by itself: say why if it matters, and start again in a moment.
      $status = $parts[1]
      if ($status -eq "MicrophoneUnavailable") { Say ("The microphone " + $mic.Name + " isn't available: another app may be using it only for itself, or desktop apps aren't allowed the microphone (Settings > Privacy & security > Microphone). Trying again shortly.") Yellow }
      elseif ($status -ne "Success" -and $status -ne "TimeoutExceeded" -and $status -ne "UserCanceled") { Say ("Listening stopped (" + $status + "). Starting again.") Yellow }
      if (-not $script:quit) { $restartAt = (Get-Date).AddSeconds(2) }
      continue
    }
    # A result: Windows' verdict (High, Medium, Low, Rejected), its raw score, the words, and how loud the mic got.
    $verdict = $parts[1]
    $raw = [double]::Parse($parts[2], [Globalization.CultureInfo]::InvariantCulture)
    $text = $parts[3]
    $pct = "{0} verdict, {1:0}% raw, mic peak {2}" -f $verdict.ToLowerInvariant(), ($raw * 100), $script:loudest
    $script:loudest = 0
    if (-not $text -or $verdict -eq "Rejected") {
      Say "Heard talking, not the phrase." DarkGray
    } elseif ($rank[$verdict] -lt $rank[$MinVerdict]) {
      Say ("Heard something like `"" + $text + "`" ($pct): not sure enough, ignored. Say it again, a little clearer.") DarkYellow
    } elseif (((Get-Date) - $last).TotalSeconds -lt $GraceSecs) {
      Say ("Heard `"" + $text + "`" ($pct): it's opening now, ignored.") DarkGray
    } elseif (Test-AssistantOpen) {
      Say ("Heard `"" + $text + "`" ($pct): the assistant is already open, ignored. Close it to call it again.") DarkGray
    } elseif ($script:paused) {
      Say ("Heard `"" + $text + "`" ($pct): paused, so not opening.") DarkGray
    } else {
      Say ("Heard `"" + $text + "`" ($pct): opening the assistant.") Cyan
      $script:lastHeard = (Get-Date -Format "HH:mm") + " opened"; Set-TrayText
      $last = Get-Date
      # Let go of the microphone first, so the assistant gets it cleanly.
      Stop-Session $recognizer; $recognizer = $null
      $handedOver = $true
      Say "The assistant is open: not listening until it closes." DarkGray
      try { Open-Assistant } catch { Say ("Couldn't open the assistant: " + $_.Exception.Message) Red }
      break
    }
  }
  if ($handedOver) { continue }

  # Watchdog: sound on the mic for a minute but no word from the speech engine: it's stuck, so start afresh.
  if ($recognizer -and ((Get-Date) - $script:lastEventAt).TotalSeconds -ge 60) {
    if ($script:soundSinceEvent -ge 15) { Say "Hearing sound but the speech engine has gone quiet: restarting listening." DarkYellow; $restartAt = Get-Date }
    $script:lastEventAt = Get-Date; $script:soundSinceEvent = 0
  }

  # Silent too long: say so once (the meter should move when you talk).
  if ($recognizer -and ((Get-Date) - $since).TotalSeconds -ge 20) {
    if ($script:windowLoudest -lt 2 -and -not $quietWarned) { Say ("No sound at all from " + $mic.Name + " for 20 seconds: check its mute button and its input volume (Settings > System > Sound > Input).") Yellow; $quietWarned = $true }
    if ($script:windowLoudest -ge 2) { $quietWarned = $false }
    $script:windowLoudest = 0; $since = Get-Date
  }

  [System.Windows.Forms.Application]::DoEvents()
  Show-Meter
  Start-Sleep -Milliseconds 100
}

# Quit from the tray: tidy up.
Stop-Session $recognizer
$script:tray.Visible = $false
$script:tray.Dispose()
