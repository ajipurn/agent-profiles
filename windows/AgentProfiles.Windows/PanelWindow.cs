using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Effects;

namespace AgentProfiles.Windows;

/// <summary>
/// The panel that opens from the tray icon, laid out like the Mac one:
/// estimated cost, a tab per provider, the selected provider's usage, the
/// other accounts to switch to, then actions. Rebuilt whenever the state changes.
/// </summary>
public sealed class PanelWindow : Window
{
    const double PanelWidth = 360;
    readonly AppState state;
    readonly StackPanel content = new() { Margin = new Thickness(12) };
    string selected = "claude";
    string costPeriod = "today";

    public event Action? OpenSettings;
    public event Action? QuitRequested;
    public event Action<string, string>? Failed;

    public PanelWindow(AppState state)
    {
        this.state = state;
        Title = "Agent Profiles";
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Width = PanelWidth + 24;
        SizeToContent = SizeToContent.Height;
        Content = new Border
        {
            Margin = new Thickness(12),
            CornerRadius = new CornerRadius(10),
            Background = Theme.Window,
            BorderBrush = Theme.CardBorder,
            BorderThickness = new Thickness(1),
            Effect = new DropShadowEffect { BlurRadius = 18, ShadowDepth = 2, Opacity = 0.28 },
            Child = content,
        };
        Deactivated += (_, _) => Hide();
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) Hide();
            if (e.Key == Key.R && Keyboard.Modifiers == ModifierKeys.Control) _ = state.RefreshAsync(force: true);
        };
        SizeChanged += (_, _) => Place();
        state.Changed += () => { if (IsVisible) Build(); };
    }

    public void Toggle()
    {
        if (IsVisible)
        {
            Hide();
            return;
        }
        selected = state.DisplayedId;
        Build();
        Show();
        Place();
        Activate();
        _ = state.RefreshAsync();
    }

    /// <summary>By the notification area: bottom right, or top right with the taskbar on top.</summary>
    void Place()
    {
        var area = SystemParameters.WorkArea;
        Left = area.Right - ActualWidth;
        Top = area.Top > 0 ? area.Top : area.Bottom - ActualHeight;
    }

    void Build()
    {
        content.Children.Clear();
        if (state.Busy is { } busy) content.Children.Add(Notice(busy + "…", Theme.Accent));
        content.Children.Add(CostCard());
        content.Children.Add(Tabs());
        switch (selected)
        {
            case "claude": BuildClaude(); break;
            case "codex": BuildCodex(); break;
            default: BuildProvider(selected); break;
        }
        content.Children.Add(Actions());
    }

    // MARK: Cost

    UIElement CostCard()
    {
        var panel = new StackPanel();
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        header.Children.Add(Label("Cost", 14, FontWeights.SemiBold));
        var periods = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        foreach (var (key, title) in new[] { ("today", "Today"), ("yesterday", "Yesterday"), ("last30Days", "30 Days") })
        {
            var button = Chip(title, key == costPeriod, () => { costPeriod = key; Build(); });
            periods.Children.Add(button);
        }
        DockPanel.SetDock(periods, Dock.Right);
        header.Children.Insert(0, periods);
        panel.Children.Add(header);

        if (state.Cost is not { } cost)
        {
            panel.Children.Add(Secondary(state.Errors.GetValueOrDefault("cost") ?? "Adding up local logs…"));
            return Card(panel);
        }
        var period = costPeriod switch { "yesterday" => cost.Yesterday, "last30Days" => cost.Last30Days, _ => cost.Today };
        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.4, GridUnitType.Star) });
        var total = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        total.Children.Add(Label(Format.Dollars(period.Total.Dollars), 24, FontWeights.SemiBold));
        total.Children.Add(Secondary("est."));
        row.Children.Add(total);
        var split = new StackPanel();
        split.Children.Add(CostLine("Claude", period.Claude, "#D97757"));
        split.Children.Add(CostLine("Codex", period.Codex, "#4C6EF5"));
        Grid.SetColumn(split, 1);
        row.Children.Add(split);
        panel.Children.Add(row);
        return Card(panel);
    }

    static UIElement CostLine(string name, CostAmount amount, string hex)
    {
        // Docked left and right first; the last child fills the middle.
        var line = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
        var dot = new System.Windows.Shapes.Ellipse { Width = 8, Height = 8, Fill = Theme.Hex(hex), Margin = new Thickness(0, 0, 8, 0) };
        DockPanel.SetDock(dot, Dock.Left);
        line.Children.Add(dot);
        var value = Label(Format.Dollars(amount.Dollars), 13, FontWeights.SemiBold);
        DockPanel.SetDock(value, Dock.Right);
        line.Children.Add(value);
        var text = new StackPanel();
        text.Children.Add(Label(name, 13, FontWeights.Medium));
        text.Children.Add(Secondary(Format.Tokens(amount.Tokens)));
        line.Children.Add(text);
        return line;
    }

    // MARK: Tabs

    UIElement Tabs()
    {
        var ids = new List<string> { "claude", "codex" };
        ids.AddRange(state.Settings.EnabledProviders);
        if (!ids.Contains(selected)) selected = "claude";
        var grid = new UniformGrid { Rows = 1, Margin = new Thickness(0, 10, 0, 10) };
        foreach (var id in ids)
        {
            var (session, weekly) = state.Headline(id);
            var left = session ?? weekly;
            var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
            stack.Children.Add(Label(state.Title(id), 12, FontWeights.SemiBold, center: true));
            stack.Children.Add(new TextBlock
            {
                Text = Format.Percent(left), FontSize = 11, Foreground = Theme.Level(left),
                HorizontalAlignment = HorizontalAlignment.Center,
            });
            var tab = new Border
            {
                Child = stack, Padding = new Thickness(4, 6, 4, 6), Margin = new Thickness(2), CornerRadius = new CornerRadius(8),
                Background = id == selected ? Theme.Selected : Brushes.Transparent, Cursor = Cursors.Hand,
            };
            var target = id;
            tab.MouseLeftButtonUp += (_, _) => { selected = target; Build(); };
            grid.Children.Add(tab);
        }
        return new Border { Child = grid, Background = Theme.Track, CornerRadius = new CornerRadius(10), Padding = new Thickness(2) };
    }

    // MARK: Claude

    void BuildClaude()
    {
        var active = state.ActiveClaude;
        var limits = new StackPanel();
        if (state.Usage?.Claude is not { Count: > 0 })
        {
            limits.Children.Add(Secondary(state.Errors.GetValueOrDefault("usage")
                ?? "No Claude Desktop profiles yet. Set them up in Settings."));
        }
        else if (active?.Usage is not { } usage)
        {
            limits.Children.Add(Secondary("No usage seen yet. Claude Desktop shows it once it has checked its limits."));
        }
        else
        {
            AddLimit(limits, "Session", usage.Session);
            AddLimit(limits, "Weekly", usage.Weekly);
            foreach (var scoped in usage.Scoped ?? []) AddLimit(limits, scoped.Name ?? "Model", scoped);
            if (usage.ExtraUsage is { } extra)
            {
                var spent = $"{extra.Used:0.00} {extra.Currency}" + (extra.Limit is { } cap ? $" of {cap:0.00}" : "");
                limits.Children.Add(Detail("Extra usage", spent));
            }
        }
        content.Children.Add(UsageCard("Claude", "#D97757", active?.Name, null,
                                       active?.Usage is { } u ? Format.Updated(u.AsOf) : null, limits));

        var others = (state.Usage?.Claude ?? []).Where(profile => !profile.Active).ToList();
        if (others.Count > 0)
            content.Children.Add(Accounts(others.Select(profile => (profile.Name, profile.Name,
                profile.Usage?.Session?.Left, profile.Usage?.Weekly?.Left)), "claude"));
        if (state.Lists?.ClaudeCode is { Count: > 0 } code) content.Children.Add(ClaudeCodePicker(code));
    }

    UIElement ClaudeCodePicker(List<NamedProfile> profiles)
    {
        var row = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
        row.Children.Add(Label("Claude Code", 13, FontWeights.Medium));
        var picker = new ComboBox { MinWidth = 140, HorizontalAlignment = HorizontalAlignment.Right };
        foreach (var profile in profiles)
        {
            picker.Items.Add(new ComboBoxItem { Content = profile.Name ?? "Default", Tag = profile.Name ?? "default" });
            if (profile.Active) picker.SelectedIndex = picker.Items.Count - 1;
        }
        picker.SelectionChanged += async (_, _) =>
        {
            if (picker.SelectedItem is ComboBoxItem { Tag: string name }
                && profiles.FirstOrDefault(profile => profile.Active)?.Name != (name == "default" ? null : name))
                Report(await state.PerformAsync("Switching Claude Code", "switch", "claude-cli", name), "Claude Code");
        };
        DockPanel.SetDock(picker, Dock.Right);
        row.Children.Insert(0, picker);
        return Card(row, padding: 10);
    }

    // MARK: Codex

    void BuildCodex()
    {
        var codex = state.Usage?.Codex;
        var limits = new StackPanel();
        if (codex is null)
        {
            limits.Children.Add(Secondary(state.Errors.GetValueOrDefault("usage") ?? "Loading usage…"));
        }
        else if (codex.Error is { } error)
        {
            limits.Children.Add(Secondary(error));
        }
        else
        {
            AddLimit(limits, "Session", codex.Session);
            AddLimit(limits, "Weekly", codex.Weekly);
            foreach (var extra in codex.Additional ?? []) AddLimit(limits, extra.Name ?? "Model", extra);
        }
        content.Children.Add(UsageCard("Codex", "#4C6EF5", codex?.Account?.Name ?? codex?.Account?.Email, codex?.Plan,
                                       Format.Updated(codex?.FetchedAt), limits));
        var saved = state.SavedCodex;
        if (saved.Count > 0)
            content.Children.Add(Accounts(saved.Select(entry => (entry.Account.Id, entry.Account.Email ?? entry.Account.Name,
                entry.Usage?.Session?.Left, entry.Usage?.Weekly?.Left)), "codex"));
    }

    // MARK: More Providers

    void BuildProvider(string id)
    {
        var provider = state.Providers.FirstOrDefault(entry => entry.Id == id);
        var limits = new StackPanel();
        if (provider is null)
        {
            limits.Children.Add(Secondary(state.Errors.GetValueOrDefault("providers") ?? "Loading usage…"));
        }
        else
        {
            if (provider.Error is { } error) limits.Children.Add(Notice(error, Theme.Level(5)));
            string? group = null;
            foreach (var window in provider.Windows ?? [])
            {
                if (window.Group is { } heading && heading != group)
                {
                    limits.Children.Add(Label(heading, 13, FontWeights.SemiBold, margin: new Thickness(0, group is null ? 0 : 6, 0, 4)));
                }
                group = window.Group;
                AddLimit(limits, window.Title, new UsageWindow(window.UsedPercent, window.ResetsAt), grouped: window.Group is not null);
            }
            foreach (var detail in provider.Details ?? []) limits.Children.Add(Detail(detail.Title, detail.Value));
            if (provider is { Error: null, Windows.Count: 0, Details.Count: 0 }) limits.Children.Add(Secondary("No usage limits reported."));
        }
        content.Children.Add(UsageCard(provider?.Name ?? state.Title(id), provider?.BrandHex ?? "#808080", provider?.Account,
                                       provider?.Plan, Format.Updated(provider?.FetchedAt), limits));
    }

    // MARK: Pieces

    UIElement UsageCard(string name, string hex, string? account, string? plan, string? updated, UIElement limits)
    {
        var panel = new StackPanel();
        var header = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 8) };
        header.Children.Add(new System.Windows.Shapes.Ellipse
        {
            Width = 28, Height = 28, Fill = Theme.Hex(hex), Opacity = 0.85, Margin = new Thickness(0, 0, 10, 0),
            VerticalAlignment = VerticalAlignment.Center,
        });
        var titles = new StackPanel();
        var line = new StackPanel { Orientation = Orientation.Horizontal };
        line.Children.Add(Label(name, 16, FontWeights.SemiBold));
        if (plan is { Length: > 0 })
            line.Children.Add(new Border
            {
                Child = Label(plan, 10, FontWeights.SemiBold), Background = Theme.Track, CornerRadius = new CornerRadius(6),
                Padding = new Thickness(6, 1, 6, 1), Margin = new Thickness(8, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center,
            });
        titles.Children.Add(line);
        var subtitle = string.Join(" · ", new[] { account, updated }.Where(text => !string.IsNullOrEmpty(text)));
        if (subtitle.Length > 0) titles.Children.Add(Secondary(subtitle));
        header.Children.Add(titles);
        panel.Children.Add(header);
        panel.Children.Add(Card(limits));
        return panel;
    }

    void AddLimit(Panel panel, string title, UsageWindow? window, bool grouped = false)
    {
        if (window is null) return;
        var row = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
        row.Children.Add(grouped ? Secondary(title, 12) : Label(title, 13, FontWeights.SemiBold));
        row.Children.Add(Bar(window.Left, 7, new Thickness(0, 5, 0, 5)));
        var numbers = new DockPanel();
        var reset = Secondary(Format.Reset(window.ResetsAt) ?? "");
        DockPanel.SetDock(reset, Dock.Right);
        numbers.Children.Add(reset);
        numbers.Children.Add(Label(Format.Share(window.Left, state.Settings.ShowUsed), 12, FontWeights.Medium));
        row.Children.Add(numbers);
        panel.Children.Add(row);
    }

    UIElement Accounts(IEnumerable<(string Id, string Title, double? Session, double? Weekly)> accounts, string provider)
    {
        var list = new StackPanel();
        foreach (var account in accounts)
        {
            var row = new Grid { Margin = new Thickness(0, 3, 0, 3) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(70) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new TextBlock
            {
                Text = account.Title, FontSize = 12, Foreground = Theme.Text, TextTrimming = TextTrimming.CharacterEllipsis,
                VerticalAlignment = VerticalAlignment.Center,
            });
            var bars = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 8, 0) };
            bars.Children.Add(Bar(account.Session, 4, new Thickness(0, 0, 0, 3)));
            bars.Children.Add(Bar(account.Weekly, 4, new Thickness(0)));
            Grid.SetColumn(bars, 1);
            row.Children.Add(bars);
            var target = account.Id;
            var button = ActionButton("Switch", async () =>
            {
                var name = provider == "codex"
                    ? state.SavedCodex.FirstOrDefault(entry => entry.Account.Id == target)?.Account is { } codex ? codex.Email ?? codex.Name : target
                    : target;
                Report(await state.PerformAsync($"Switching {state.Title(provider)} to {name}", "switch", provider, name),
                       state.Title(provider));
            }, small: true);
            button.IsEnabled = state.Busy is null;
            Grid.SetColumn(button, 2);
            row.Children.Add(button);
            list.Children.Add(row);
        }
        var panel = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
        panel.Children.Add(Secondary("Switch to", 11));
        panel.Children.Add(Card(list, padding: 10));
        return panel;
    }

    UIElement Actions()
    {
        var row = new UniformGrid { Rows = 1, Margin = new Thickness(0, 12, 0, 0) };
        row.Children.Add(ActionButton("Refresh", () => _ = state.RefreshAsync(force: true)));
        row.Children.Add(ActionButton("Settings", () => { Hide(); OpenSettings?.Invoke(); }));
        row.Children.Add(ActionButton("Quit", () => QuitRequested?.Invoke()));
        return row;
    }

    void Report(string? failure, string title)
    {
        if (failure is not null) Failed?.Invoke($"{title}: switch failed", failure);
    }

    static Border Card(UIElement child, double padding = 12) => new()
    {
        Child = child, Background = Theme.Card, BorderBrush = Theme.CardBorder, BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(8), Padding = new Thickness(padding),
    };

    static Grid Bar(double? left, double height, Thickness margin)
    {
        var value = Math.Clamp(left ?? 0, 0, 100);
        var grid = new Grid { Height = height, Margin = margin };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(value, 0.001), GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(100 - value, 0.001), GridUnitType.Star) });
        var track = new Border { Background = Theme.Track, CornerRadius = new CornerRadius(height / 2) };
        Grid.SetColumnSpan(track, 2);
        grid.Children.Add(track);
        if (left is not null && value > 0)
            grid.Children.Add(new Border { Background = Theme.Level(left), CornerRadius = new CornerRadius(height / 2) });
        return grid;
    }

    static TextBlock Label(string text, double size, FontWeight weight, bool center = false, Thickness? margin = null) => new()
    {
        Text = text, FontSize = size, FontWeight = weight, Foreground = Theme.Text,
        TextTrimming = TextTrimming.CharacterEllipsis, Margin = margin ?? new Thickness(0),
        HorizontalAlignment = center ? HorizontalAlignment.Center : HorizontalAlignment.Left,
    };

    static TextBlock Secondary(string text, double size = 11) => new()
    {
        Text = text, FontSize = size, Foreground = Theme.Secondary, TextWrapping = TextWrapping.Wrap,
    };

    static UIElement Detail(string title, string value)
    {
        var row = new DockPanel { Margin = new Thickness(0, 0, 0, 6) };
        var text = Label(value, 12, FontWeights.SemiBold);
        DockPanel.SetDock(text, Dock.Right);
        row.Children.Add(text);
        row.Children.Add(Label(title, 12, FontWeights.Normal));
        return row;
    }

    static UIElement Notice(string text, Brush tint) => new Border
    {
        Child = new TextBlock { Text = text, FontSize = 12, Foreground = tint, TextWrapping = TextWrapping.Wrap },
        Background = Theme.Track, CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 8, 10, 8),
        Margin = new Thickness(0, 0, 0, 10),
    };

    static Border Chip(string title, bool on, Action action)
    {
        var chip = new Border
        {
            Child = new TextBlock { Text = title, FontSize = 11, FontWeight = on ? FontWeights.SemiBold : FontWeights.Normal, Foreground = on ? Theme.Text : Theme.Secondary },
            Background = on ? Theme.Selected : Brushes.Transparent, CornerRadius = new CornerRadius(8),
            Padding = new Thickness(8, 3, 8, 3), Cursor = Cursors.Hand,
        };
        chip.MouseLeftButtonUp += (_, _) => action();
        return chip;
    }

    static Button ActionButton(string title, Action action, bool small = false)
    {
        var button = new Button
        {
            Content = title, Margin = new Thickness(small ? 0 : 3, 0, small ? 0 : 3, 0),
            Padding = small ? new Thickness(10, 2, 10, 2) : new Thickness(8, 6, 8, 6), FontSize = small ? 11 : 12,
        };
        button.Click += (_, _) => action();
        return button;
    }
}
