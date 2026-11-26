using System;
using System.Collections.Concurrent;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace WakeUi {
  /// <summary>
  /// The floating Tyrone button: a rounded pill drawn into a per-pixel-alpha
  /// (layered) window, so its edges are smooth and it never flickers. It only
  /// redraws when what it shows changes. What you do with it comes out as
  /// events: "start", "stop", "front", "activity", "menu", "moved|x,y".
  /// </summary>
  public class Pill : Form {
    public readonly ConcurrentQueue<string> Clicks = new ConcurrentQueue<string>();
    string title = "Tyrone", status = "Starting", info = "", action = "";
    Color dot = Color.FromArgb(251, 191, 36);
    int level = -1;
    float scale = 1f;
    Rectangle actionBox = Rectangle.Empty;
    Point downAt; bool dragging, down;

    [DllImport("user32.dll")] static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref Point pptDst, ref Size psize, IntPtr hdcSrc, ref Point pptSrc, int crKey, ref Blend pblend, int dwFlags);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr hDC);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr hObject);
    [StructLayout(LayoutKind.Sequential, Pack = 1)] struct Blend { public byte Op, Flags, Alpha, Format; }

    public Pill() {
      FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; StartPosition = FormStartPosition.Manual;
      using (var g = CreateGraphics()) scale = g.DpiX / 96f;
    }
    protected override CreateParams CreateParams {
      get { var cp = base.CreateParams; cp.ExStyle |= 0x00080000 /* layered */ | 0x00000080 /* tool window */ | 0x08000000 /* no activate */; return cp; }
    }
    protected override bool ShowWithoutActivation { get { return true; } }

    /// <summary>What it shows. Redraws only when something changed.</summary>
    public void Display(string status, Color dot, string info, string action, int level) {
      if (status == this.status && dot == this.dot && info == this.info && action == this.action && level == this.level && Visible) return;
      this.status = status; this.dot = dot; this.info = info ?? ""; this.action = action ?? ""; this.level = level;
      Render();
    }

    int S(float v) { return (int)Math.Round(v * scale); }

    public void Render() {
      if (!IsHandleCreated) CreateHandle();
      {
        // Drawn in pixels at the screen's DPI, so it's sharp on a scaled display.
        int w = S(info.Length > 0 ? 260 : 220), h = S(info.Length > 0 ? 66 : 50);
        using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
        using (var g = Graphics.FromImage(bmp)) {
          g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
          g.Clear(Color.Transparent);
          using (var path = Round(new RectangleF(0.5f, 0.5f, w - 1, h - 1), S(14)))
          using (var fill = new LinearGradientBrush(new Point(0, 0), new Point(0, h), Color.FromArgb(242, 22, 48, 80), Color.FromArgb(242, 12, 30, 54)))
          using (var edge = new Pen(Color.FromArgb(90, 148, 163, 184), Math.Max(1, scale))) { g.FillPath(fill, path); g.DrawPath(edge, path); }
          // The status dot, with a soft halo.
          using (var halo = new SolidBrush(Color.FromArgb(60, dot))) g.FillEllipse(halo, S(12), S(15), S(20), S(20));
          using (var b = new SolidBrush(dot)) g.FillEllipse(b, S(16), S(19), S(12), S(12));
          using (var tf = new Font("Segoe UI Semibold", 10.5f * 96f / 72f * scale, GraphicsUnit.Pixel))
          using (var sf = new Font("Segoe UI", 8.75f * 96f / 72f * scale, GraphicsUnit.Pixel))
          using (var bf = new Font("Segoe UI Semibold", 9f * 96f / 72f * scale, GraphicsUnit.Pixel)) {
            g.DrawString(title, tf, Brushes.White, S(38), S(5));
            using (var muted = new SolidBrush(Color.FromArgb(203, 213, 225))) {
              g.DrawString(status, sf, muted, S(39), S(26));
              if (info.Length > 0) g.DrawString(info, sf, muted, new RectangleF(S(14), S(45), w - S(24), S(18)), new StringFormat { Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap });
            }
            // The mic level, a thin bar under the title, while listening.
            if (level >= 0) {
              using (var track = new SolidBrush(Color.FromArgb(70, 148, 163, 184))) g.FillRectangle(track, S(92), S(14), S(40), S(3));
              using (var b = new SolidBrush(dot)) g.FillRectangle(b, S(92), S(14), S(40) * Math.Min(100, level) / 100, S(3));
            }
            // The Start or Stop button.
            actionBox = Rectangle.Empty;
            if (action.Length > 0) {
              var size = g.MeasureString(action, bf);
              actionBox = new Rectangle(w - S(14) - (int)size.Width - S(20), S(11), (int)size.Width + S(20), S(28));
              var stop = action == "Stop";
              using (var p = Round(actionBox, S(14)))
              using (var b = new SolidBrush(stop ? Color.FromArgb(190, 18, 60) : Color.FromArgb(234, 88, 12))) g.FillPath(b, p);
              g.DrawString(action, bf, Brushes.White, actionBox.X + S(10), actionBox.Y + (actionBox.Height - size.Height) / 2);
            }
          }
          Apply(bmp);
        }
      }
    }

    static GraphicsPath Round(RectangleF r, float radius) {
      var p = new GraphicsPath(); float d = radius * 2;
      p.AddArc(r.X, r.Y, d, d, 180, 90); p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
      p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.X, r.Bottom - d, d, d, 90, 90); p.CloseFigure();
      return p;
    }

    /// <summary>The last picture drawn (for the self-test).</summary>
    public Bitmap Last;
    void Apply(Bitmap bmp) {
      if (Last != null) Last.Dispose();
      Last = (Bitmap)bmp.Clone();
      IntPtr screen = GetDC(IntPtr.Zero), mem = CreateCompatibleDC(screen), hbmp = bmp.GetHbitmap(Color.FromArgb(0)), old = SelectObject(mem, hbmp);
      try {
        var size = new Size(bmp.Width, bmp.Height); var src = new Point(0, 0); var dst = new Point(Left, Top);
        var blend = new Blend { Op = 0, Flags = 0, Alpha = 255, Format = 1 };
        Size = size;
        UpdateLayeredWindow(Handle, screen, ref dst, ref size, mem, ref src, 0, ref blend, 2);
      } finally { SelectObject(mem, old); DeleteObject(hbmp); DeleteDC(mem); ReleaseDC(IntPtr.Zero, screen); }
    }

    protected override void OnMouseDown(MouseEventArgs e) {
      if (e.Button == MouseButtons.Right) { Clicks.Enqueue("menu"); return; }
      if (e.Button != MouseButtons.Left) return;
      down = true; dragging = false; downAt = e.Location;
    }
    protected override void OnMouseMove(MouseEventArgs e) {
      if (!down) return;
      if (!dragging && Math.Abs(e.X - downAt.X) + Math.Abs(e.Y - downAt.Y) > S(4)) dragging = true;
      if (dragging) { Left += e.X - downAt.X; Top += e.Y - downAt.Y; }
    }
    protected override void OnMouseUp(MouseEventArgs e) {
      if (e.Button != MouseButtons.Left || !down) return;
      down = false;
      if (dragging) { Clicks.Enqueue("moved|" + Left + "," + Top); return; }
      if (actionBox.Contains(e.Location)) Clicks.Enqueue(action == "Stop" ? "stop" : "start");
      else Clicks.Enqueue("front");
    }
    protected override void OnMouseDoubleClick(MouseEventArgs e) {
      if (e.Button == MouseButtons.Left && !actionBox.Contains(e.Location)) Clicks.Enqueue("activity");
    }
  }

  /// <summary>
  /// The activity window: what the listener is doing, newest at the bottom.
  /// Closing it only hides it; the listener keeps running in the tray.
  /// </summary>
  public class Activity : Form {
    readonly RichTextBox log;
    readonly Label meter;
    public Activity(string title) {
      float k; using (var g = CreateGraphics()) k = g.DpiX / 96f;
      Text = title; Width = (int)(780 * k); Height = (int)(480 * k); StartPosition = FormStartPosition.CenterScreen; ShowInTaskbar = true;
      BackColor = Color.FromArgb(12, 30, 54); Font = new Font("Segoe UI", 9.5f);
      meter = new Label { Dock = DockStyle.Bottom, Height = (int)(30 * k), ForeColor = Color.FromArgb(203, 213, 225), BackColor = Color.FromArgb(22, 48, 80), Padding = new Padding(10, 6, 10, 0), Font = new Font("Consolas", 9.5f) };
      log = new RichTextBox { Dock = DockStyle.Fill, ReadOnly = true, BorderStyle = BorderStyle.None, BackColor = Color.FromArgb(12, 30, 54), ForeColor = Color.FromArgb(226, 232, 240), Font = new Font("Consolas", 9.5f), DetectUrls = false };
      Controls.Add(log); Controls.Add(meter);
    }
    protected override void OnFormClosing(FormClosingEventArgs e) {
      if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
      base.OnFormClosing(e);
    }
    public void Add(string line, Color color) {
      if (log.TextLength > 200000) { log.Select(0, 50000); log.SelectedText = ""; }
      log.SelectionStart = log.TextLength; log.SelectionLength = 0; log.SelectionColor = color;
      log.AppendText(line + Environment.NewLine);
      log.SelectionStart = log.TextLength; log.ScrollToCaret();
    }
    public void Meter(string text) { if (meter.Text != text) meter.Text = text; }
    public void Bring() { Show(); if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal; Activate(); }
  }
}
