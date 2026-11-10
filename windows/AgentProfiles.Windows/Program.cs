using System;
using System.Threading;
using System.Windows;

namespace AgentProfiles.Windows;

/// <summary>
/// A tray app: no main window, one instance. The icon, the panel and Settings
/// all draw the same <see cref="AppState"/>.
/// </summary>
public static class Program
{
    [STAThread]
    public static void Main()
    {
        using var single = new Mutex(initiallyOwned: true, @"Local\AgentProfiles.Windows", out var first);
        if (!first) return;

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var state = new AppState();
        using var tray = new TrayIcon();
        using var foreground = new ForegroundWatcher();
        var panel = new PanelWindow(state);
        SettingsWindow? settings = null;

        void Fail(string title, string message) => tray.Notify(title, message, error: true);

        void ShowSettings()
        {
            if (settings is null)
            {
                settings = new SettingsWindow(state);
                settings.Failed += Fail;
                settings.Closed += (_, _) => settings = null;
            }
            settings.Show();
            settings.Activate();
        }

        void UpdateTray()
        {
            var id = state.DisplayedId;
            var (session, weekly) = state.Headline(id);
            var lines = $"Agent Profiles — {state.Title(id)}\nSession: {Format.Share(session, false)}\nWeekly: {Format.Share(weekly, false)}";
            if (state.Busy is { } busy) lines = busy + "…";
            tray.Update(session, weekly, lines);
        }

        tray.Clicked += panel.Toggle;
        tray.OpenSettings += ShowSettings;
        tray.RefreshRequested += () => _ = state.RefreshAsync(force: true);
        tray.QuitRequested += app.Shutdown;
        panel.OpenSettings += ShowSettings;
        panel.QuitRequested += app.Shutdown;
        panel.Failed += Fail;
        foreground.ProviderActivated += provider =>
        {
            if (state.ActiveApp == provider) return;
            state.ActiveApp = provider;
            UpdateTray();
        };
        state.Changed += UpdateTray;
        state.ActiveApp = ForegroundWatcher.ProviderFor(ForegroundWatcher.GetForegroundWindow());

        state.Start();
        app.Run();
    }
}
