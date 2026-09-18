using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows;
using Forms = System.Windows.Forms;

namespace GitHubSignal.Windows;

internal sealed class TrayService : IDisposable
{
    private readonly Forms.NotifyIcon tray;
    private readonly Icon original;
    private Icon? counter;
    private int lastCount = -1;
    private bool disposed;
    [DllImport("user32.dll")] private static extern bool DestroyIcon(IntPtr handle);
    public TrayService(Action show, Action quit)
    {
        using var resource = Application.GetResourceStream(new Uri("pack://application:,,,/Assets/AppIcon.ico"))!.Stream;
        original = new Icon(resource, 32, 32);
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("通知一覧を開く", null, (_, _) => show());
        menu.Items.Add("終了", null, (_, _) => quit());
        tray = new Forms.NotifyIcon { Icon = original, Text = "GitHub Signal", ContextMenuStrip = menu, Visible = true };
        tray.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) show(); };
        tray.BalloonTipClicked += (_, _) => show();
    }
    public void SetCount(int count)
    {
        if (disposed || count == lastCount) return;
        lastCount = count;
        Icon? next = null;
        if (count > 0) {
            using var bitmap = new Bitmap(32, 32);
            using var graphics = Graphics.FromImage(bitmap);
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.Clear(Color.Transparent);
            using var background = new SolidBrush(Color.FromArgb(28, 113, 77));
            graphics.FillEllipse(background, 0, 0, 32, 32);
            using var font = new Font("Segoe UI", count > 99 ? 11 : 16, System.Drawing.FontStyle.Bold, GraphicsUnit.Pixel);
            using var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            graphics.DrawString(count > 99 ? "99+" : count.ToString(), font, Brushes.White, new RectangleF(0, 0, 32, 32), format);
            var handle = bitmap.GetHicon();
            try { using var borrowed = Icon.FromHandle(handle); next = (Icon)borrowed.Clone(); }
            finally { DestroyIcon(handle); }
        }
        tray.Icon = next ?? original;
        counter?.Dispose(); counter = next;
        tray.Text = count > 0 ? $"GitHub Signal · 未確認 {count}件" : "GitHub Signal · 未確認なし";
    }
    public bool Notify(string title, string body)
    {
        if (disposed || !Forms.SystemInformation.UserInteractive) return false;
        tray.BalloonTipTitle = title;
        tray.BalloonTipText = body.Length > 240 ? body[..240] + "…" : body;
        tray.BalloonTipIcon = Forms.ToolTipIcon.None;
        tray.ShowBalloonTip(10000);
        return true; // Windows accepted the request; Focus Assist can still suppress its display.
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        tray.Visible = false;
        tray.ContextMenuStrip?.Dispose(); tray.Dispose();
        counter?.Dispose(); original.Dispose();
    }
}
