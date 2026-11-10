using System;
using System.Globalization;

namespace AgentProfiles.Windows;

public static class Format
{
    /// <summary>"85% left", or "15% used" when Settings says so.</summary>
    public static string Share(double? left, bool showUsed) =>
        left is not { } value ? "—"
        : showUsed ? $"{Math.Round(100 - value)}% used"
        : $"{Math.Round(value)}% left";

    /// <summary>The compact form for tabs and the tray icon: "85%".</summary>
    public static string Percent(double? left) => left is { } value ? $"{Math.Round(value)}%" : "—";

    public static string? Reset(DateTimeOffset? at)
    {
        if (at is not { } date) return null;
        var left = date - DateTimeOffset.Now;
        if (left <= TimeSpan.Zero) return "Resets now";
        return "Resets in " + Duration(left);
    }

    public static string Duration(TimeSpan span)
    {
        if (span.TotalDays >= 1) return $"{(int)span.TotalDays}d {span.Hours}h";
        if (span.TotalHours >= 1) return $"{(int)span.TotalHours}h {span.Minutes}m";
        return $"{Math.Max(1, (int)Math.Ceiling(span.TotalMinutes))}m";
    }

    public static string Updated(DateTimeOffset? at)
    {
        if (at is not { } date) return "";
        var age = DateTimeOffset.Now - date;
        return age < TimeSpan.FromMinutes(1) ? "Updated just now" : $"Updated {Duration(age)} ago";
    }

    public static string Dollars(double value) => value.ToString("$0.00", CultureInfo.InvariantCulture);

    public static string Tokens(long tokens) => tokens switch
    {
        >= 1_000_000 => $"{tokens / 1_000_000.0:0.0}M tokens",
        >= 1_000 => $"{tokens / 1_000.0:0.0}K tokens",
        _ => $"{tokens} tokens",
    };
}
