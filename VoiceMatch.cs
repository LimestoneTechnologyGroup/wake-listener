// The wake listener's ear: it compares what the microphone hears with recordings
// of you saying the phrase. No speech recognizer and nothing sent anywhere.
//
//   Fingerprint  sound -> a voice fingerprint, 100 frames a second (MFCCs: the
//                standard description of how speech sounds, 100-4000 Hz, so it
//                behaves the same on a Bluetooth headset and a desk mic).
//   Segmenter    cuts the live sound into separate bits of talking, against the
//                room's own background level.
//   Voice        your recordings; scores how close a bit of talking is to them,
//                allowing for saying it faster or slower (dynamic time warping).
//   Listener     the default microphone (waveIn) -> Segmenter -> Voice, reporting
//                into a queue the PowerShell script reads.
//
// Written for the C# compiler Windows PowerShell 5.1 uses (C# 5).

using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Speech.AudioFormat;
using System.Speech.Synthesis;
using System.Text;
using System.Threading;

namespace WakeVoice {

  public static class Fingerprint {
    public const int Rate = 16000, Win = 400, Hop = 160, NFft = 512, NMel = 20, NCep = 12;
    public const int Dim = NCep * 2;
    static readonly double[] window = new double[Win];
    static readonly double[][] mel = new double[NMel][];
    static readonly double[,] dct = new double[NCep, NMel];

    static Fingerprint() {
      for (int i = 0; i < Win; i++) window[i] = 0.54 - 0.46 * Math.Cos(2 * Math.PI * i / (Win - 1));
      int bins = NFft / 2 + 1;
      Func<double, double> toMel = f => 2595 * Math.Log10(1 + f / 700.0);
      Func<double, double> toHz = m => 700 * (Math.Pow(10, m / 2595.0) - 1);
      double lo = toMel(100), hi = toMel(4000);
      var pts = new double[NMel + 2];
      for (int i = 0; i < NMel + 2; i++) pts[i] = toHz(lo + (hi - lo) * i / (NMel + 1)) * NFft / Rate;
      for (int m = 0; m < NMel; m++) {
        mel[m] = new double[bins];
        double l = pts[m], c = pts[m + 1], r = pts[m + 2];
        for (int k = 0; k < bins; k++) {
          double w = k < l || k > r ? 0 : k <= c ? (k - l) / (c - l) : (r - k) / (r - c);
          mel[m][k] = Math.Max(0, w);
        }
      }
      for (int c = 0; c < NCep; c++)
        for (int m = 0; m < NMel; m++) dct[c, m] = Math.Cos(Math.PI * (c + 1) * (m + 0.5) / NMel);
    }

    /// <summary>One fingerprint frame per 10 ms: 12 cepstral values and how each is changing.</summary>
    public static float[][] Frames(short[] s) {
      int n = s.Length < Win ? 0 : 1 + (s.Length - Win) / Hop;
      var cep = new double[n][];
      var re = new double[NFft];
      var im = new double[NFft];
      var logmel = new double[NMel];
      for (int f = 0; f < n; f++) {
        int o = f * Hop;
        double prev = o > 0 ? s[o - 1] : s[o];
        for (int i = 0; i < NFft; i++) {
          if (i < Win) { double x = s[o + i]; re[i] = (x - 0.97 * prev) * window[i]; prev = x; } else re[i] = 0;
          im[i] = 0;
        }
        Fft(re, im);
        for (int m = 0; m < NMel; m++) {
          double e = 0; var w = mel[m];
          for (int k = 0; k < w.Length; k++) if (w[k] > 0) e += w[k] * (re[k] * re[k] + im[k] * im[k]);
          logmel[m] = Math.Log(e + 1.0);
        }
        var c = new double[NCep];
        for (int k = 0; k < NCep; k++) { double v = 0; for (int m = 0; m < NMel; m++) v += dct[k, m] * logmel[m]; c[k] = v; }
        cep[f] = c;
      }
      var result = new float[n][];
      for (int f = 0; f < n; f++) {
        var v = new float[Dim];
        for (int k = 0; k < NCep; k++) {
          v[k] = (float)cep[f][k];
          double d = 0, den = 0;
          for (int t = 1; t <= 2; t++) { d += t * (cep[Math.Min(n - 1, f + t)][k] - cep[Math.Max(0, f - t)][k]); den += 2 * t * t; }
          v[NCep + k] = (float)(d / den);
        }
        result[f] = v;
      }
      return result;
    }

    static void Fft(double[] re, double[] im) {
      int n = re.Length;
      for (int i = 1, j = 0; i < n; i++) {
        int bit = n >> 1;
        for (; (j & bit) != 0; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) { double t = re[i]; re[i] = re[j]; re[j] = t; t = im[i]; im[i] = im[j]; im[j] = t; }
      }
      for (int len = 2; len <= n; len <<= 1) {
        double ang = -2 * Math.PI / len, wr = Math.Cos(ang), wi = Math.Sin(ang);
        for (int i = 0; i < n; i += len) {
          double cr = 1, ci = 0;
          for (int k = 0; k < len / 2; k++) {
            int a = i + k, b = a + len / 2;
            double xr = re[b] * cr - im[b] * ci, xi = re[b] * ci + im[b] * cr;
            re[b] = re[a] - xr; im[b] = im[a] - xi; re[a] += xr; im[a] += xi;
            double t = cr * wr - ci * wi; ci = cr * wi + ci * wr; cr = t;
          }
        }
      }
    }

    /// <summary>Loudness of each 10 ms, in dB below full scale.</summary>
    public static double[] Loudness(short[] s) {
      var r = new double[s.Length / Hop];
      for (int i = 0; i < r.Length; i++) r[i] = Db(s, i * Hop, Hop);
      return r;
    }
    public static double Db(short[] s, int start, int count) {
      double sum = 0;
      for (int i = start; i < start + count; i++) sum += (double)s[i] * s[i];
      return 10 * Math.Log10(sum / Math.Max(1, count) + 1) - 90.3;
    }
  }

  /// <summary>Cuts live sound into bits of talking: louder than the room for a moment, then quiet again.</summary>
  public class Segmenter {
    const int Step = Fingerprint.Hop;             // 10 ms
    const double Above = 9;                        // dB over the room's background = talking
    const double Floor = -70;                      // never treat anything quieter than this as talking
    const int StartSteps = 4, EndSteps = 30, PreSteps = 25, MinSteps = 25, MaxSteps = 400, KeepSteps = 150;
    double background = double.NaN;
    readonly List<short> partial = new List<short>();
    readonly Queue<short[]> before = new Queue<short[]>();
    List<short[]> current;
    int loudRun, quietRun;
    public double Background { get { return background; } }

    public List<short[]> Push(short[] samples) {
      var done = new List<short[]>();
      partial.AddRange(samples);
      int at = 0;
      while (partial.Count - at >= Step) {
        var step = partial.GetRange(at, Step).ToArray();
        at += Step;
        Take(step, done);
      }
      partial.RemoveRange(0, at);
      return done;
    }

    void Take(short[] step, List<short[]> done) {
      double db = Fingerprint.Db(step, 0, step.Length);
      if (double.IsNaN(background)) background = db;
      // The background follows quiet quickly and noise slowly (about 5 seconds).
      background += (db < background ? 0.1 : 0.002) * (db - background);
      bool loud = db > background + Above && db > Floor;
      if (current == null) {
        before.Enqueue(step);
        if (before.Count > PreSteps) before.Dequeue();
        loudRun = loud ? loudRun + 1 : 0;
        if (loudRun >= StartSteps) { current = new List<short[]>(before); before.Clear(); quietRun = 0; }
        return;
      }
      current.Add(step);
      quietRun = loud ? 0 : quietRun + 1;
      if (quietRun >= EndSteps) {
        if (current.Count - quietRun >= MinSteps) done.Add(Join(current));
        current = null; loudRun = 0;
      } else if (current.Count >= MaxSteps) {
        // Long talk: judge what's there, and carry on with its last 1.5 seconds.
        done.Add(Join(current));
        current = current.Skip(current.Count - KeepSteps).ToList();
      }
    }

    static short[] Join(List<short[]> steps) {
      var r = new short[steps.Sum(s => s.Length)];
      int o = 0;
      foreach (var s in steps) { Array.Copy(s, 0, r, o, s.Length); o += s.Length; }
      return r;
    }
  }

  /// <summary>Your recordings of the phrase, and how close new talk is to them.</summary>
  public class Voice {
    readonly List<float[][]> templates = new List<float[][]>();
    float[] mean = new float[Fingerprint.Dim], spread = new float[Fingerprint.Dim];
    /// <summary>A score (distance) at or under this opens the assistant.</summary>
    public double Threshold { get; private set; }
    public string Report { get; private set; }
    public int Samples { get { return templates.Count; } }

    public static Voice Train(IList<short[]> said, IList<short[]> other) {
      var v = Build(said, other);
      // A recording that sounds nothing like the others (a cough, a half-said
      // phrase, someone talking over it) is left out, and the rest relearned.
      var keep = new List<short[]>();
      var median = v.mine.OrderBy(d => d).ElementAt(v.mine.Count / 2);
      for (int i = 0; i < said.Count; i++) if (v.mine[i] <= median * 1.5) keep.Add(said[i]);
      if (keep.Count < said.Count && keep.Count >= 4) {
        int left = said.Count - keep.Count;
        v = Build(keep, other);
        v.Report += " " + left + (left == 1 ? " recording didn't" : " recordings didn't") + " sound like the others and " + (left == 1 ? "was" : "were") + " left out.";
      }
      return v;
    }
    List<double> mine;

    static Voice Build(IList<short[]> said, IList<short[]> other) {
      if (said.Count < 3) throw new InvalidOperationException("At least 3 recordings of the phrase are needed.");
      var v = new Voice();
      var raw = said.Select(s => Fingerprint.Frames(Trim(s))).Where(f => f.Length > 10).ToList();
      if (raw.Count < 3) throw new InvalidOperationException("The recordings were too short.");
      int total = 0;
      foreach (var r in raw) foreach (var f in r) { for (int k = 0; k < f.Length; k++) v.mean[k] += f[k]; total++; }
      for (int k = 0; k < v.mean.Length; k++) v.mean[k] /= total;
      foreach (var r in raw) foreach (var f in r) for (int k = 0; k < f.Length; k++) v.spread[k] += (f[k] - v.mean[k]) * (f[k] - v.mean[k]);
      for (int k = 0; k < v.spread.Length; k++) v.spread[k] = (float)Math.Sqrt(v.spread[k] / total) + 1e-3f;
      foreach (var r in raw) v.templates.Add(v.Normalize(r));

      // Each recording against the others: how far apart your own "hey Tyrone"s are.
      var mine = new List<double>();
      for (int i = 0; i < said.Count; i++) mine.Add(v.Score(said[i], i));
      v.mine = mine;
      var talk = other.Select(o => v.Score(o, -1)).Where(d => d < double.MaxValue).ToList();
      var sorted = mine.Where(d => d < double.MaxValue).OrderBy(d => d).ToList();
      // Allow for one off-sample when there are plenty.
      double farthest = sorted.Count == 0 ? 1 : sorted[sorted.Count >= 6 ? sorted.Count - 2 : sorted.Count - 1];
      double nearestTalk = talk.Count > 0 ? talk.Min() : double.MaxValue;
      v.Threshold = nearestTalk < double.MaxValue ? (farthest + nearestTalk) / 2 : farthest * 1.15;
      if (nearestTalk < double.MaxValue && nearestTalk < farthest) v.Threshold = Math.Max(v.Threshold, farthest * 0.97);

      var inv = CultureInfo.InvariantCulture;
      var mineClose = sorted.Select(d => 100 * v.Threshold / d).ToList();
      int opens = mine.Count(d => d <= v.Threshold);
      v.Report = string.Format(inv, "{0} recordings: each scores {1:0}% to {2:0}% against the others ({3} of {0} would open).",
        said.Count, mineClose.Count > 0 ? mineClose.Min() : 0, mineClose.Count > 0 ? mineClose.Max() : 0, opens);
      if (talk.Count > 0)
        v.Report += string.Format(inv, " Ordinary talk: {0} bits, the closest {1:0}% ({2} would open).",
          talk.Count, 100 * v.Threshold / nearestTalk, talk.Count(d => d <= v.Threshold));
      return v;
    }

    /// <summary>How close this talk is to the phrase: 100 or more opens. sensitivity above 1 opens more easily.</summary>
    public double Closeness(short[] talk, double sensitivity) {
      var d = Score(talk, -1);
      return d >= double.MaxValue ? 0 : 100 * Threshold * sensitivity / d;
    }

    double Score(short[] talk, int skip) {
      var u = Normalize(Fingerprint.Frames(talk));
      var d = new List<double>();
      for (int i = 0; i < templates.Count; i++) if (i != skip) d.Add(Match(templates[i], u));
      d.Sort();
      var best = d.Where(x => x < double.MaxValue).Take(3).ToList();
      return best.Count == 0 ? double.MaxValue : best.Average();
    }

    float[][] Normalize(float[][] frames) {
      return frames.Select(f => { var r = new float[f.Length]; for (int k = 0; k < f.Length; k++) r[k] = (f[k] - mean[k]) / spread[k]; return r; }).ToArray();
    }

    /// <summary>The phrase with the quiet before and after taken off.</summary>
    static short[] Trim(short[] s) {
      var db = Fingerprint.Loudness(s);
      if (db.Length == 0) return s;
      double top = db.Max();
      int first = Array.FindIndex(db, x => x > top - 30), last = Array.FindLastIndex(db, x => x > top - 30);
      first = Math.Max(0, first - 3); last = Math.Min(db.Length - 1, last + 3);
      int from = first * Fingerprint.Hop, to = Math.Min(s.Length, (last + 1) * Fingerprint.Hop + Fingerprint.Win);
      var r = new short[to - from];
      Array.Copy(s, from, r, 0, r.Length);
      return r;
    }

    /// <summary>
    /// The phrase found anywhere inside the talk (it may start or end with other
    /// words), stretched or squeezed to fit: the average distance per step of the
    /// best fit, or MaxValue when nothing of a sensible length fits.
    /// </summary>
    static double Match(float[][] t, float[][] u) {
      int m = t.Length, n = u.Length;
      if (m == 0 || n < m / 2) return double.MaxValue;
      // Each cell keeps its best path's total cost C, its weight W (a diagonal step
      // counts 2, others 1) and where in the talk it started. Paths starting at
      // different places have different weights, so they're compared by C / W.
      var prevC = new double[n]; var prevW = new int[n]; var prevS = new int[n];
      var curC = new double[n]; var curW = new int[n]; var curS = new int[n];
      for (int j = 0; j < n; j++) { prevC[j] = Dist(t[0], u[j]); prevW[j] = 1; prevS[j] = j; }
      for (int i = 1; i < m; i++) {
        double d0 = Dist(t[i], u[0]);
        curC[0] = prevC[0] + d0; curW[0] = prevW[0] + 1; curS[0] = prevS[0];
        for (int j = 1; j < n; j++) {
          double d = Dist(t[i], u[j]);
          double diag = (prevC[j - 1] + 2 * d) / (prevW[j - 1] + 2);
          double up = (prevC[j] + d) / (prevW[j] + 1);
          double left = (curC[j - 1] + d) / (curW[j - 1] + 1);
          if (diag <= up && diag <= left) { curC[j] = prevC[j - 1] + 2 * d; curW[j] = prevW[j - 1] + 2; curS[j] = prevS[j - 1]; }
          else if (up <= left) { curC[j] = prevC[j] + d; curW[j] = prevW[j] + 1; curS[j] = prevS[j]; }
          else { curC[j] = curC[j - 1] + d; curW[j] = curW[j - 1] + 1; curS[j] = curS[j - 1]; }
        }
        var tc = prevC; prevC = curC; curC = tc;
        var tw = prevW; prevW = curW; curW = tw;
        var ts = prevS; prevS = curS; curS = ts;
      }
      double best = double.MaxValue;
      for (int j = 0; j < n; j++) {
        int span = j - prevS[j] + 1;
        if (span < m / 2 || span > m * 2) continue;
        double score = prevC[j] / prevW[j];
        if (score < best) best = score;
      }
      return best;
    }

    static double Dist(float[] a, float[] b) {
      double s = 0;
      for (int k = 0; k < a.Length; k++) { double d = a[k] - b[k]; s += d * d; }
      return Math.Sqrt(s);
    }
  }

  /// <summary>
  /// The default microphone, cut into bits of talking and judged against your voice.
  /// Events: "wake|closeness|seconds", "heard|closeness|seconds", "captured|seconds".
  /// </summary>
  public class Listener {
    public readonly ConcurrentQueue<string> Events = new ConcurrentQueue<string>();
    public readonly ConcurrentQueue<short[]> Captured = new ConcurrentQueue<short[]>();
    /// <summary>While training, bits of talking are kept in Captured instead of judged.</summary>
    public volatile bool Training;
    public Voice Voice;
    public double Sensitivity = 1.0;
    readonly Segmenter segmenter = new Segmenter();
    Mic mic;
    int peak;
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    /// <summary>Opens the default microphone. Throws why not.</summary>
    public void Start() {
      // Testing on a PC without a microphone: a recording plays in its place.
      var fake = Environment.GetEnvironmentVariable("WAKE_LISTENER_FAKE_MIC");
      mic = string.IsNullOrEmpty(fake) ? new Mic(Push) : new Mic(Push, Wav.Read(fake));
    }
    public void Stop() { var m = mic; mic = null; if (m != null) m.Close(); }
    /// <summary>Seconds since the microphone last delivered sound (it delivers silence too, ten times a second).</summary>
    public double SecondsSinceSound { get { var m = mic; return m == null ? 0 : (DateTime.UtcNow - m.LastData).TotalSeconds; } }
    /// <summary>The loudest it's been since the last call, 0 to 100.</summary>
    public int TakePeak() { return Interlocked.Exchange(ref peak, 0); }

    /// <summary>Sound in (from the microphone, or the self-test).</summary>
    public void Push(short[] samples) {
      int p = 0;
      foreach (var x in samples) { int a = x < 0 ? -x : x; if (a > p) p = a; }
      int level = (int)Math.Min(100, Math.Round(Math.Sqrt(p / 32768.0) * 100));
      int was;
      do { was = peak; if (level <= was) break; } while (Interlocked.CompareExchange(ref peak, level, was) != was);
      foreach (var talk in segmenter.Push(samples)) Judge(talk);
    }

    void Judge(short[] talk) {
      var secs = ((double)talk.Length / Fingerprint.Rate).ToString("0.0", Inv);
      if (Training) { Captured.Enqueue(talk); Events.Enqueue("captured|" + secs); return; }
      var v = Voice;
      if (v == null) { Events.Enqueue("heard|0|" + secs); return; }
      double c = v.Closeness(talk, Sensitivity);
      Events.Enqueue((c >= 100 ? "wake|" : "heard|") + c.ToString("0", Inv) + "|" + secs);
    }
  }

  /// <summary>The Windows default microphone (waveIn, default-device mapper), 16 kHz mono, in 100 ms pieces.</summary>
  public class Mic {
    const int BufferBytes = Fingerprint.Rate * 2 / 10, Buffers = 8;
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
    readonly Action<short[]> sink;
    readonly Thread pump;
    volatile bool closed;
    public DateTime LastData = DateTime.UtcNow;

    public Mic(Action<short[]> sink) {
      this.sink = sink;
      var format = new WaveFormat { wFormatTag = 1, nChannels = 1, nSamplesPerSec = Fingerprint.Rate, wBitsPerSample = 16, nBlockAlign = 2, nAvgBytesPerSec = Fingerprint.Rate * 2 };
      int result = waveInOpen(out device, 0xFFFFFFFF, ref format, signal.SafeWaitHandle.DangerousGetHandle(), IntPtr.Zero, 0x50000);
      if (result != 0) throw new IOException(
        result == 2 ? "No microphone is available to open (waveIn error 2)." :
        result == 4 ? "The microphone is in use by another program that won't share it (waveIn error 4)." :
        "The microphone couldn't be opened (waveIn error " + result + ").");
      for (int i = 0; i < Buffers; i++) {
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
        signal.WaitOne(200);
        for (int i = 0; i < Buffers && !closed; i++) {
          var hdr = (WaveHdr)Marshal.PtrToStructure(headers[i], typeof(WaveHdr));
          if ((hdr.dwFlags & 1) == 0) continue;
          if (hdr.dwBytesRecorded > 0) {
            var data = new short[hdr.dwBytesRecorded / 2];
            Marshal.Copy(hdr.lpData, data, 0, data.Length);
            LastData = DateTime.UtcNow;
            try { sink(data); } catch { }
          }
          waveInUnprepareHeader(device, headers[i], HdrSize);
          hdr.dwFlags = 0; hdr.dwBytesRecorded = 0;
          Marshal.StructureToPtr(hdr, headers[i], false);
          waveInPrepareHeader(device, headers[i], HdrSize);
          waveInAddBuffer(device, headers[i], HdrSize);
        }
      }
    }

    /// <summary>For testing: plays a recording in real time, over and over, in place of the microphone.</summary>
    public Mic(Action<short[]> sink, short[] recording) {
      this.sink = sink;
      fake = true;
      pump = new Thread(() => {
        int at = 0;
        while (!closed) {
          var piece = new short[1600];
          for (int i = 0; i < piece.Length; i++) piece[i] = recording[(at + i) % recording.Length];
          at = (at + piece.Length) % recording.Length;
          LastData = DateTime.UtcNow;
          try { sink(piece); } catch { }
          Thread.Sleep(100);
        }
      }) { IsBackground = true, Name = "Recording" };
      pump.Start();
    }
    readonly bool fake;

    public void Close() {
      if (closed) return;
      closed = true;
      if (fake) { pump.Join(2000); return; }
      waveInReset(device);
      pump.Join(2000);
      for (int i = 0; i < Buffers; i++) {
        if (headers[i] == IntPtr.Zero) continue;
        waveInUnprepareHeader(device, headers[i], HdrSize);
        var hdr = (WaveHdr)Marshal.PtrToStructure(headers[i], typeof(WaveHdr));
        Marshal.FreeHGlobal(hdr.lpData);
        Marshal.FreeHGlobal(headers[i]);
        headers[i] = IntPtr.Zero;
      }
      waveInClose(device);
    }
  }

  /// <summary>Recordings on disk: 16 kHz, 16-bit mono WAV files.</summary>
  public static class Wav {
    public static void Write(string path, short[] s) {
      using (var w = new BinaryWriter(File.Create(path))) {
        w.Write(Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + s.Length * 2); w.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
        w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(Fingerprint.Rate); w.Write(Fingerprint.Rate * 2); w.Write((short)2); w.Write((short)16);
        w.Write(Encoding.ASCII.GetBytes("data")); w.Write(s.Length * 2);
        foreach (var x in s) w.Write(x);
      }
    }
    public static short[] Read(string path) {
      var b = File.ReadAllBytes(path);
      int at = 12;
      while (at + 8 <= b.Length) {
        string id = Encoding.ASCII.GetString(b, at, 4);
        int size = BitConverter.ToInt32(b, at + 4);
        if (id == "data") { size = Math.Min(size, b.Length - at - 8); var s = new short[size / 2]; Buffer.BlockCopy(b, at + 8, s, 0, s.Length * 2); return s; }
        at += 8 + size + (size & 1);
      }
      throw new InvalidDataException("No sound in " + path);
    }
    /// <summary>Your voice from its folder (said_*.wav, talk_*.wav), or null when there are fewer than 3 recordings.</summary>
    public static Voice Load(string folder) {
      if (!Directory.Exists(folder)) return null;
      var said = Directory.GetFiles(folder, "said_*.wav").OrderBy(f => f).Select(Read).ToList();
      var talk = Directory.GetFiles(folder, "talk_*.wav").OrderBy(f => f).Select(Read).ToList();
      return said.Count < 3 ? null : Voice.Train(said, talk);
    }
  }

  /// <summary>For the self-test: Windows' own voices saying things, with a little room noise around them.</summary>
  public static class TestKit {
    public static string[] Voices() {
      using (var s = new SpeechSynthesizer())
        return s.GetInstalledVoices().Where(x => x.Enabled).Select(x => x.VoiceInfo.Name).ToArray();
    }
    public static short[] Say(string text, string voice, int rate, int seed) {
      byte[] b;
      using (var s = new SpeechSynthesizer()) {
        if (!string.IsNullOrEmpty(voice)) s.SelectVoice(voice);
        s.Rate = rate;
        var ms = new MemoryStream();
        s.SetOutputToAudioStream(ms, new SpeechAudioFormatInfo(Fingerprint.Rate, AudioBitsPerSample.Sixteen, AudioChannel.Mono));
        s.Speak(text);
        s.SetOutputToNull();
        b = ms.ToArray();
      }
      var clip = new short[b.Length / 2];
      Buffer.BlockCopy(b, 0, clip, 0, clip.Length * 2);
      // A second of room before and after, and quiet hiss throughout.
      var rnd = new Random(seed);
      var r = new short[clip.Length + 2 * Fingerprint.Rate];
      for (int i = 0; i < r.Length; i++) {
        int j = i - Fingerprint.Rate;
        double x = (j >= 0 && j < clip.Length ? clip[j] * 0.6 : 0) + (rnd.NextDouble() - 0.5) * 60;
        r[i] = (short)Math.Max(short.MinValue, Math.Min(short.MaxValue, x));
      }
      return r;
    }
    /// <summary>Feeds sound through a listener in 100 ms pieces, as the microphone would, and returns its events.</summary>
    public static string[] Hear(Listener l, short[] sound) {
      for (int at = 0; at < sound.Length; at += 1600) {
        var piece = new short[Math.Min(1600, sound.Length - at)];
        Array.Copy(sound, at, piece, 0, piece.Length);
        l.Push(piece);
      }
      var r = new List<string>(); string e;
      while (l.Events.TryDequeue(out e)) r.Add(e);
      return r.ToArray();
    }
  }
}
