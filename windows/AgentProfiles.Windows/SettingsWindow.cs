using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;

namespace AgentProfiles.Windows;

/// <summary>
/// Settings: what the tray icon shows, which More Providers are on, setting
/// Claude Desktop and Claude Code profiles up, adding Codex accounts, and
/// launching at sign-in.
/// </summary>
public sealed class SettingsWindow : Window
{
    readonly AppState state;
    readonly StackPanel content = new() { Margin = new Thickness(20) };

    public event Action<string, string>? Failed;

    public SettingsWindow(AppState state)
    {
        this.state = state;
        Title = "Agent Profiles Settings";
        Width = 520;
        Height = 640;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = Theme.Window;
        Content = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        state.Changed += () => { if (IsVisible) Build(); };
        Build();
        _ = state.LoadProviderInfosAsync();
    }

    void Build()
    {
        content.Children.Clear();

        Section("Tray icon");
        var showFor = new ComboBox { Width = 220, HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var id in new[] { "claude", "codex" }.Concat(state.Settings.EnabledProviders))
        {
            showFor.Items.Add(new ComboBoxItem { Content = state.Title(id), Tag = id });
            if (id == state.Settings.ShowUsageFor) showFor.SelectedIndex = showFor.Items.Count - 1;
        }
        showFor.SelectionChanged += (_, _) =>
        {
            if (showFor.SelectedItem is ComboBoxItem { Tag: string id }) Change(() => state.Settings.ShowUsageFor = id);
        };
        Row("Show usage for", showFor);
        Check("Follow the active app", state.Settings.FollowActiveApp, on => Change(() => state.Settings.FollowActiveApp = on));
        Check("Show used instead of left", state.Settings.ShowUsed, on => Change(() => state.Settings.ShowUsed = on));
        Note("The top bar is the session window, the bottom bar the weekly one. When following the active app, " +
             "bringing Claude, ChatGPT/Codex or Antigravity to the front switches the icon to it.");

        Section("More Providers");
        if (state.ProviderInfos.Count == 0) Note(state.Errors.GetValueOrDefault("providers") ?? "Looking for providers…");
        foreach (var provider in state.ProviderInfos)
        {
            var on = state.Settings.EnabledProviders.Contains(provider.Id);
            Check(provider.Name + (provider.SignedIn ? "" : " (not signed in)"), on, enabled => Change(() =>
            {
                state.Settings.EnabledProviders.Remove(provider.Id);
                if (enabled) state.Settings.EnabledProviders.Add(provider.Id);
            }, refreshProviders: true));
        }
        Note("Each reads the sign-in its own app or CLI keeps on this PC, and sends it only to its own service.");

        Section("Claude Desktop");
        var claudeProfiles = state.Lists?.Claude ?? [];
        if (claudeProfiles.Count == 0)
        {
            Note("Save the Claude account signed in now as your first profile. Claude closes and opens again.");
            NameAction("Name", "main", "Set up profiles", name =>
                state.PerformAsync("Setting up Claude Desktop profiles", "setup", "claude", name));
        }
        else
        {
            Note("Profiles: " + string.Join(", ", claudeProfiles.Select(profile => profile.Name + (profile.Active ? " (in use)" : ""))));
            NameAction("New profile", "", "Create", name => state.PerformAsync("Creating a profile", "new", "claude", name));
        }

        Section("Claude Code");
        Note("Each Claude Code profile is its own config folder. A small claude.cmd placed first on your PATH picks the one chosen in the panel.");
        var install = new Button { Content = "Install the claude profile shim", Padding = new Thickness(10, 4, 10, 4), HorizontalAlignment = HorizontalAlignment.Left };
        install.Click += async (_, _) => await InstallShimAsync();
        content.Children.Add(install);
        NameAction("New Claude Code profile", "", "Create", name => state.PerformAsync("Creating a profile", "new", "claude-cli", name));

        Section("Codex");
        Note("Add an account: a console opens to sign in with codex login. The account in use stays saved and comes back if you cancel.");
        var add = new Button { Content = "Add Codex account…", Padding = new Thickness(10, 4, 10, 4), HorizontalAlignment = HorizontalAlignment.Left };
        add.Click += (_, _) => AddCodexAccount();
        content.Children.Add(add);

        Section("Startup");
        Check("Launch at sign-in", Startup.IsEnabled, on => Startup.Set(on));
        Note($"Engine: {state.Engine.Executable}");
    }

    async System.Threading.Tasks.Task InstallShimAsync()
    {
        try
        {
            var setup = await state.Engine.RunAsync<ShimSetup>("setup", "claude-cli");
            var folder = Path.GetDirectoryName(setup.Shim)!;
            if (UserPath.StartsWith(folder))
            {
                MessageBox.Show(this, "The claude profile shim is installed and first on your PATH.", "Claude Code");
                return;
            }
            var answer = MessageBox.Show(this,
                $"Installed {setup.Shim}.\n\nPut its folder first on your PATH now? Terminals opened afterwards use it.",
                "Claude Code", MessageBoxButton.YesNo);
            if (answer == MessageBoxResult.Yes) UserPath.Prepend(folder);
        }
        catch (EngineException exception)
        {
            Failed?.Invoke("Claude Code setup failed", exception.Message);
        }
    }

    void AddCodexAccount()
    {
        // In its own console, so codex can show its sign-in link and wait.
        var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"))
        {
            UseShellExecute = true,
            Arguments = $"/d /c title Agent Profiles - Codex sign-in & \"{state.Engine.Executable}\" login codex & pause",
        };
        try
        {
            using var process = Process.Start(start);
            process?.WaitForExitAsync().ContinueWith(_ => Dispatcher.Invoke(() => _ = state.RefreshAsync(force: true)));
        }
        catch (System.ComponentModel.Win32Exception exception)
        {
            Failed?.Invoke("Codex sign-in could not start", exception.Message);
        }
    }

    void Change(Action change, bool refreshProviders = false)
    {
        change();
        state.Settings.Save();
        if (refreshProviders) _ = state.RefreshProvidersAsync().ContinueWith(_ => Dispatcher.Invoke(Build));
        else Build();
    }

    void NameAction(string label, string initial, string action, Func<string, System.Threading.Tasks.Task<string?>> perform)
    {
        var box = new TextBox { Text = initial, Width = 180, Margin = new Thickness(0, 0, 8, 0) };
        var button = new Button { Content = action, Padding = new Thickness(10, 2, 10, 2) };
        button.Click += async (_, _) =>
        {
            var name = box.Text.Trim();
            if (name.Length == 0) return;
            if (await perform(name) is { } failure) Failed?.Invoke(label + " failed", failure);
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(box);
        row.Children.Add(button);
        Row(label, row);
    }

    void Section(string title) => content.Children.Add(new TextBlock
    {
        Text = title, FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = Theme.Text,
        Margin = new Thickness(0, content.Children.Count == 0 ? 0 : 18, 0, 8),
    });

    void Row(string label, UIElement control)
    {
        var row = new DockPanel { Margin = new Thickness(0, 4, 0, 4) };
        var text = new TextBlock { Text = label, Width = 170, Foreground = Theme.Text, VerticalAlignment = VerticalAlignment.Center };
        DockPanel.SetDock(text, Dock.Left);
        row.Children.Add(text);
        row.Children.Add(control);
        content.Children.Add(row);
    }

    void Check(string label, bool on, Action<bool> changed)
    {
        var box = new CheckBox { Content = label, IsChecked = on, Foreground = Theme.Text, Margin = new Thickness(0, 4, 0, 4) };
        box.Checked += (_, _) => changed(true);
        box.Unchecked += (_, _) => changed(false);
        content.Children.Add(box);
    }

    void Note(string text) => content.Children.Add(new TextBlock
    {
        Text = text, FontSize = 11, Foreground = Theme.Secondary, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 6),
    });
}
