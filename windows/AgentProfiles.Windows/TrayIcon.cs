using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using Forms = System.Windows.Forms;

namespace AgentProfiles.Windows;

/// <summary>
/// The notification-area icon: two bars, the session window on top and the
/// weekly one below, like the Mac menu bar icon. The tooltip carries the numbers.
/// </summary>
public sealed class TrayIcon : IDisposable
{
    readonly Forms.NotifyIcon icon = new() { Visible = true, Text = "Agent Profiles" };
    Icon? current;

    public event Action? Clicked;
    public event Action? OpenSettings;
    public event Action? RefreshRequested;
    public event Action? QuitRequested;

    public TrayIcon()
    {
        icon.MouseUp += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left) Clicked?.Invoke();
        };
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open", null, (_, _) => Clicked?.Invoke());
        menu.Items.Add("Refresh", null, (_, _) => RefreshRequested?.Invoke());
        menu.Items.Add("Settings…", null, (_, _) => OpenSettings?.Invoke());
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit Agent Profiles", null, (_, _) => QuitRequested?.Invoke());
        icon.ContextMenuStrip = menu;
        Update(null, null, "Agent Profiles");
    }

    public void Update(double? session, double? weekly, string tooltip)
    {
        var next = Render(session, weekly);
        icon.Icon = next;
        current?.Dispose();
        current = next;
        // Windows cuts tooltips at 127 characters.
        icon.Text = tooltip.Length > 127 ? tooltip[..126] + "…" : tooltip;
    }

    public void Notify(string title, string text, bool error = false) =>
        icon.ShowBalloonTip(5000, title, text, error ? Forms.ToolTipIcon.Warning : Forms.ToolTipIcon.Info);

    static Icon Render(double? session, double? weekly)
    {
        const int size = 32;
        using var bitmap = new Bitmap(size, size);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.Clear(Color.Transparent);
            var track = Theme.TaskbarIsLight ? Color.FromArgb(70, 0, 0, 0) : Color.FromArgb(90, 255, 255, 255);
            DrawBar(graphics, new RectangleF(2, 6, 28, 8), session, track);
            DrawBar(graphics, new RectangleF(2, 18, 28, 8), weekly, track);
        }
        var handle = bitmap.GetHicon();
        try
        {
            return (Icon)Icon.FromHandle(handle).Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    static void DrawBar(Graphics graphics, RectangleF bounds, double? left, Color track)
    {
        using (var path = Rounded(bounds))
        using (var brush = new SolidBrush(track))
            graphics.FillPath(brush, path);
        if (left is not { } value || value <= 0) return;
        var fill = new RectangleF(bounds.X, bounds.Y, Math.Max(bounds.Height, bounds.Width * (float)(value / 100)), bounds.Height);
        var color = value <= 10 ? Color.FromArgb(232, 72, 64)
            : value <= 25 ? Color.FromArgb(240, 176, 40)
            : Theme.TaskbarIsLight ? Color.FromArgb(30, 30, 30) : Color.White;
        using (var path = Rounded(fill))
        using (var brush = new SolidBrush(color))
            graphics.FillPath(brush, path);
    }

    static GraphicsPath Rounded(RectangleF bounds)
    {
        var radius = bounds.Height / 2;
        var path = new GraphicsPath();
        path.AddArc(bounds.X, bounds.Y, radius * 2, bounds.Height, 90, 180);
        path.AddArc(bounds.Right - radius * 2, bounds.Y, radius * 2, bounds.Height, 270, 180);
        path.CloseFigure();
        return path;
    }

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr handle);

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
        current?.Dispose();
    }
}
