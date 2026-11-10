using System;
using System.Collections.Generic;

namespace AgentProfiles.Windows;

// The shapes agent-profiles.exe prints with --json (see docs/WINDOWS.md).
// Percentages are used shares, 0-100; times are ISO 8601.

public sealed record UsageWindow(double UsedPercent, DateTimeOffset? ResetsAt, string? Name = null)
{
    public double Left => Math.Clamp(100 - UsedPercent, 0, 100);
}

public sealed record ExtraUsage(double Used, double? Limit, string Currency);

public sealed record ClaudeUsage(UsageWindow? Session, UsageWindow? Weekly, List<UsageWindow>? Scoped,
                                 ExtraUsage? ExtraUsage, DateTimeOffset AsOf);

public sealed record ClaudeProfileUsage(string Name, bool Active, ClaudeUsage? Usage);

public sealed record CodexAccount(string Id, string Name, string? Email, bool Active);

/// <summary>A Codex account's usage, or <see cref="Error"/> alone when it couldn't be read.</summary>
public sealed record CodexUsage(CodexAccount? Account, string? Plan, bool? LimitReached, UsageWindow? Session,
                                UsageWindow? Weekly, List<UsageWindow>? Additional, DateTimeOffset? FetchedAt,
                                string? Error);

public sealed record SavedCodexUsage(CodexAccount Account, CodexUsage? Usage, string? Error);

public sealed record UsageReport(List<ClaudeProfileUsage>? Claude, CodexUsage? Codex, List<SavedCodexUsage>? CodexAccounts);

public sealed record ProviderWindow(string Title, string? Group, double UsedPercent, DateTimeOffset? ResetsAt,
                                   double? WindowSeconds)
{
    public double Left => Math.Clamp(100 - UsedPercent, 0, 100);
}

public sealed record ProviderDetail(string Title, string Value, double? UsedPercent);

public sealed record ProviderUsage(string Id, string Name, string BrandHex, string? Account, string? Plan,
                                   List<ProviderWindow>? Windows, List<ProviderWindow>? Primary,
                                   List<ProviderDetail>? Details, DateTimeOffset? FetchedAt, string? Error);

public sealed record ProviderInfo(string Id, string Name, string BrandHex, bool SignedIn);

public sealed record NamedProfile(string? Name, bool Active);

public sealed record ProfileLists(List<NamedProfile>? Claude, List<NamedProfile>? ClaudeCode, List<CodexAccount>? Codex);

public sealed record CostAmount(double Dollars, long Tokens);

public sealed record CostPeriod(CostAmount Total, CostAmount Claude, CostAmount Codex);

public sealed record CostReport(CostPeriod Today, CostPeriod Yesterday, CostPeriod Last30Days, List<string>? UnpricedModels);

public sealed record ShimSetup(string Shim, string PathCommand);
