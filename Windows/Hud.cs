namespace CodexMonitor {
    using System;
    using System.Diagnostics;
    using System.Drawing;
    using System.Drawing.Drawing2D;
    using System.IO;
    using System.Runtime.InteropServices;
    using System.Threading.Tasks;
    using System.Windows.Forms;

    public sealed class Hud : Form {
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint id);
        private readonly Timer timer = new Timer { Interval = 250 };
        private readonly string settings = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexTokenMonitor", "position.txt");
        private Snapshot snapshot = new Snapshot();
        private Task<Snapshot> refresh;
        private DateTime nextRefresh = DateTime.MinValue;
        private bool expanded, docked, dragging;
        private Point dragStart;
        private readonly ContextMenuStrip menu = new ContextMenuStrip();
        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams {
            get { var p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x80; return p; }
        }
        public Hud() {
            Text = "Codex Token Monitor"; FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false; TopMost = true; DoubleBuffered = true;
            BackColor = Color.FromArgb(28, 30, 33); ForeColor = Color.WhiteSmoke;
            ClientSize = new Size(340, 96); StartPosition = FormStartPosition.Manual;
            Location = new Point(Screen.PrimaryScreen.WorkingArea.Right - 360, 80);
            try {
                if (File.Exists(settings)) {
                    var parts = File.ReadAllText(settings).Split(','); int x, y;
                    if (parts.Length == 2 && int.TryParse(parts[0], out x) && int.TryParse(parts[1], out y)) Location = new Point(x, y);
                }
            } catch (IOException) { }
            var area = Screen.FromPoint(Location).WorkingArea;
            Location = new Point(Math.Max(area.Left, Math.Min(Left, area.Right - Width)), Math.Max(area.Top, Math.Min(Top, area.Bottom - Height)));
            menu.Items.Add("Refresh", null, delegate { nextRefresh = DateTime.MinValue; });
            menu.Items.Add("Exit", null, delegate { Close(); }); ContextMenuStrip = menu;
            MouseEnter += delegate { if (!docked && !dragging) { expanded = true; ResizeSurface(); } };
            MouseLeave += delegate { if (!ClientRectangle.Contains(PointToClient(Cursor.Position)) && !dragging) { expanded = false; ResizeSurface(); } };
            MouseDown += delegate(object sender, MouseEventArgs e) {
                if (e.Button != MouseButtons.Left) return;
                dragging = true; Capture = true; dragStart = e.Location;
                if (docked) { docked = false; expanded = false; ResizeSurface(); }
            };
            MouseMove += delegate(object sender, MouseEventArgs e) { if (dragging) Location = new Point(Left + e.X - dragStart.X, Top + e.Y - dragStart.Y); };
            MouseUp += delegate {
                if (!dragging) return;
                dragging = false; Capture = false; expanded = false;
                var bounds = Screen.FromControl(this).WorkingArea;
                docked = Left <= bounds.Left + 18 || Right >= bounds.Right - 18 || Top <= bounds.Top + 18 || Bottom >= bounds.Bottom - 18;
                ResizeSurface();
                Location = new Point(Math.Max(bounds.Left, Math.Min(Left, bounds.Right - Width)), Math.Max(bounds.Top, Math.Min(Top, bounds.Bottom - Height)));
                try { Directory.CreateDirectory(Path.GetDirectoryName(settings)); File.WriteAllText(settings, Left + "," + Top); }
                catch (IOException) { } catch (UnauthorizedAccessException) { }
            };
            timer.Tick += Tick; timer.Start(); ResizeSurface();
        }
        private void ResizeSurface() {
            ClientSize = docked ? new Size(86, 86) : new Size(340, expanded ? 242 : 96);
            using (var shape = new GraphicsPath()) {
                if (docked) shape.AddEllipse(0, 0, Width - 1, Height - 1);
                else {
                    shape.AddArc(0, 0, 24, 24, 180, 90); shape.AddArc(Width - 25, 0, 24, 24, 270, 90);
                    shape.AddArc(Width - 25, Height - 25, 24, 24, 0, 90); shape.AddArc(0, Height - 25, 24, 24, 90, 90); shape.CloseFigure();
                }
                var old = Region; Region = new Region(shape); if (old != null) old.Dispose();
            }
            Invalidate();
        }
        private bool CodexForeground() {
            uint id; GetWindowThreadProcessId(GetForegroundWindow(), out id);
            try { using (var p = Process.GetProcessById((int)id)) return p.ProcessName.Equals("Codex", StringComparison.OrdinalIgnoreCase); }
            catch (ArgumentException) { return false; } catch (InvalidOperationException) { return false; }
        }
        private void Tick(object sender, EventArgs args) {
            bool show = CodexForeground() || dragging || menu.Visible;
            if (Visible != show) { if (show) Show(); else Hide(); }
            if (refresh != null && refresh.IsCompleted) {
                if (!refresh.IsFaulted && !refresh.IsCanceled) snapshot = refresh.Result;
                else snapshot.Status = "Local data unavailable - retrying";
                refresh = null; nextRefresh = DateTime.UtcNow.AddSeconds(30); Invalidate();
            }
            if (refresh == null && DateTime.UtcNow >= nextRefresh) refresh = Task.Run(() => Data.Read());
        }
        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e); var g = e.Graphics; g.SmoothingMode = SmoothingMode.AntiAlias;
            double remaining = snapshot.Used.HasValue ? 100 - snapshot.Used.Value : 0;
            var ring = docked ? new Rectangle(12, 12, 62, 62) : new Rectangle(15, 15, 66, 66);
            using (var track = new Pen(Color.FromArgb(54, 58, 62), 6)) g.DrawEllipse(track, ring);
            using (var progress = new Pen(Color.FromArgb(53, 199, 90), 6)) {
                progress.StartCap = LineCap.Round; progress.EndCap = LineCap.Round;
                if (remaining > 0) g.DrawArc(progress, ring, -90, (float)(remaining * 3.6));
            }
            using (var font = new Font("Segoe UI", 14, FontStyle.Bold))
            using (var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center })
                g.DrawString(snapshot.Used.HasValue ? remaining.ToString("0") + "%" : "--", font, Brushes.WhiteSmoke, ring, format);
            if (docked) return;
            DrawText(g, "Quota remaining", 99, 17, 210, 13, true);
            DrawText(g, snapshot.Used.HasValue ? "Used " + snapshot.Used.Value.ToString("0") + "% / 100%" : snapshot.Status, 99, 45, 225, 9, false);
            using (var track = new SolidBrush(Color.FromArgb(54, 58, 62))) g.FillRectangle(track, 100, 72, 216, 5);
            using (var fill = new SolidBrush(Color.FromArgb(53, 199, 90))) g.FillRectangle(fill, 100, 72, (float)(216 * remaining / 100), 5);
            if (expanded) {
                DrawText(g, "Recent project: " + snapshot.Project, 18, 106, 305, 10, true);
                DrawText(g, "Project window: " + Tokens(snapshot.ProjectTokens), 18, 134, 305, 10, false);
                DrawText(g, "All local projects: " + Tokens(snapshot.TotalTokens), 18, 162, 305, 10, false);
                DrawText(g, "Lifetime: " + Tokens(snapshot.Lifetime), 18, 190, 305, 10, false);
                DrawText(g, "Drag to edge to dock | Right-click to exit", 18, 218, 305, 8, false);
            }
        }
        private static string Tokens(long n) { return n >= 1000000 ? (n / 1000000.0).ToString("0.00") + "M" : n.ToString("N0"); }
        private static void DrawText(Graphics g, string text, int x, int y, int width, int size, bool bold) {
            using (var font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular))
            using (var format = new StringFormat { Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap })
                g.DrawString(text, font, Brushes.WhiteSmoke, new RectangleF(x, y, width, 22), format);
        }
        protected override void Dispose(bool disposing) { if (disposing) { timer.Dispose(); menu.Dispose(); Data.Shutdown(); } base.Dispose(disposing); }
    }
}
