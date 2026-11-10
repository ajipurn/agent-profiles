using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace AgentProfiles.Windows;

/// <summary>
/// What the engine last reported, refreshed on a schedule: profiles every
/// minute; Claude and the active Codex account every 2 minutes; every saved
/// Codex account every 10; More Providers and cost every 5.
/// </summary>
public sealed class AppState
{
    public Engine Engine { get; } = new();
    public Settings Settings { get; } = Settings.Load();

    public ProfileLists? Lists { get; private set; }
    public UsageReport? Usage { get; private set; }
    public List<SavedCodexUsage> SavedCodex { get; private set; } = [];
    public List<ProviderUsage> Providers { get; private set; } = [];
    public List<ProviderInfo> ProviderInfos { get; private set; } = [];
    public CostReport? Cost { get; private set; }

    /// <summary>Why the last read failed, per part ("claude", "codex", "providers", "cost").</summary>
    public Dictionary<string, string> Errors { get; } = [];
    /// <summary>A switch or setup in progress, said in a few words.</summary>
    public string? Busy { get; private set; }
    /// <summary>The provider of the app in front (claude, codex, antigravity), when the icon follows it.</summary>
    public string? ActiveApp { get; set; }

    public event Action? Changed;

    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMinutes(1) };
    DateTime listsAt, usageAt, savedCodexAt, providersAt, costAt;
    bool refreshing;

    public void Start()
    {
        timer.Tick += async (_, _) => await RefreshAsync();
        timer.Start();
        _ = LoadProviderInfosAsync();
        _ = RefreshAsync(force: true);
    }

    /// <summary>What the tray icon shows and the panel opens on.</summary>
    public string DisplayedId =>
        Settings.FollowActiveApp && ActiveApp is { } app && IsShowable(app) ? app
        : IsShowable(Settings.ShowUsageFor) ? Settings.ShowUsageFor
        : "claude";

    public bool IsShowable(string id) => id is "claude" or "codex" || Settings.EnabledProviders.Contains(id);

    public ClaudeProfileUsage? ActiveClaude => Usage?.Claude?.FirstOrDefault(profile => profile.Active);

    /// <summary>The icon's two bars, as shares left: session (top) and weekly (bottom).</summary>
    public (double? Session, double? Weekly) Headline(string id) => id switch
    {
        "claude" => (ActiveClaude?.Usage?.Session?.Left, ActiveClaude?.Usage?.Weekly?.Left),
        "codex" => Usage?.Codex is { Error: null } codex ? (codex.Session?.Left, codex.Weekly?.Left) : (null, null),
        _ => Providers.FirstOrDefault(provider => provider.Id == id)?.Primary is { } primary
            ? (primary.ElementAtOrDefault(0)?.Left, primary.ElementAtOrDefault(1)?.Left)
            : (null, null),
    };

    public string Title(string id) => id switch
    {
        "claude" => "Claude",
        "codex" => "Codex",
        _ => ProviderInfos.FirstOrDefault(info => info.Id == id)?.Name ?? id,
    };

    /// <summary>Reads what is due; <paramref name="force"/> reads everything now.</summary>
    public async Task RefreshAsync(bool force = false)
    {
        if (refreshing || Busy is not null) return;
        refreshing = true;
        try
        {
            var now = DateTime.UtcNow;
            if (force || now - listsAt >= TimeSpan.FromMinutes(1))
            {
                await Read("lists", async () => Lists = await Engine.RunAsync<ProfileLists>("list"));
                listsAt = now;
            }
            var allCodex = force || now - savedCodexAt >= TimeSpan.FromMinutes(10);
            if (allCodex || now - usageAt >= TimeSpan.FromMinutes(2))
            {
                await Read("usage", async () =>
                {
                    var report = await Engine.RunAsync<UsageReport>(allCodex
                        ? ["usage", "--all-codex", "--record"]
                        : ["usage", "--record"]);
                    Usage = report;
                    if (report.CodexAccounts is { } saved) SavedCodex = saved;
                });
                usageAt = now;
                if (allCodex) savedCodexAt = now;
            }
            if (force || now - providersAt >= TimeSpan.FromMinutes(5))
            {
                await RefreshProvidersAsync();
                providersAt = now;
            }
            if (force || now - costAt >= TimeSpan.FromMinutes(5))
            {
                await Read("cost", async () => Cost = await Engine.RunAsync<CostReport>("cost"));
                costAt = now;
            }
        }
        finally
        {
            refreshing = false;
            Changed?.Invoke();
        }
    }

    public async Task RefreshProvidersAsync()
    {
        var enabled = Settings.EnabledProviders.ToArray();
        if (enabled.Length == 0)
        {
            Providers = [];
            return;
        }
        await Read("providers", async () =>
            Providers = await Engine.RunAsync<List<ProviderUsage>>(["providers", "usage", .. enabled]));
    }

    public async Task LoadProviderInfosAsync()
    {
        await Read("providers", async () => ProviderInfos = await Engine.RunAsync<List<ProviderInfo>>("providers"));
        Changed?.Invoke();
    }

    /// <summary>
    /// Switches, sets up or creates through the engine, then reads everything
    /// again. Returns the failure, if any, to show.
    /// </summary>
    public async Task<string?> PerformAsync(string busy, params string[] arguments)
    {
        if (Busy is not null) return "Agent Profiles is still busy with the last change.";
        Busy = busy;
        Changed?.Invoke();
        string? failure = null;
        try
        {
            await Engine.RunAsync(arguments);
        }
        catch (EngineException exception)
        {
            failure = exception.Message;
        }
        finally
        {
            Busy = null;
        }
        await RefreshAsync(force: true);
        return failure;
    }

    async Task Read(string part, Func<Task> read)
    {
        try
        {
            await read();
            Errors.Remove(part);
        }
        catch (Exception exception) when (exception is EngineException or System.Text.Json.JsonException)
        {
            Errors[part] = exception.Message;
        }
    }
}
