using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32;

namespace AgentProfiles.Windows;

/// <summary>
/// The tray's own choices, in %APPDATA%\AgentProfiles\windows-settings.json.
/// Profiles and accounts are the engine's; nothing here touches them.
/// </summary>
public sealed class Settings
{
    /// <summary>"claude", "codex", or a More Providers id: what the tray icon shows.</summary>
    public string ShowUsageFor { get; set; } = "claude";
    /// <summary>Bringing Claude, ChatGPT/Codex or Antigravity to the front switches the icon to it.</summary>
    public bool FollowActiveApp { get; set; } = true;
    public List<string> EnabledProviders { get; set; } = [];
    public bool ShowUsed { get; set; }

    static string FilePath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "AgentProfiles",
                     "windows-settings.json");

    static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static Settings Load()
    {
        try
        {
            return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings();
        }
        catch (Exception exception) when (exception is IOException or JsonException or UnauthorizedAccessException)
        {
            return new Settings();
        }
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        var temporary = FilePath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this, Options));
        File.Move(temporary, FilePath, overwrite: true);
    }
}

/// <summary>Launch at sign-in: the current user's Run key.</summary>
public static class Startup
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "AgentProfiles";

    static string Command => $"\"{Environment.ProcessPath}\"";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(Name) is string value && value == Command;
        }
    }

    public static void Set(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(RunKey);
        if (enabled) key.SetValue(Name, Command);
        else key.DeleteValue(Name, throwOnMissingValue: false);
    }
}

/// <summary>The user's PATH, where the Claude Code profile shim has to come first.</summary>
public static class UserPath
{
    public static bool StartsWith(string folder) =>
        Entries().FirstOrDefault() is { } first && SameFolder(first, folder);

    /// <summary>Moves the folder to the front of the user PATH and tells running programs.</summary>
    public static void Prepend(string folder)
    {
        var rest = Entries().Where(entry => !SameFolder(entry, folder));
        Environment.SetEnvironmentVariable("Path", string.Join(';', new[] { folder }.Concat(rest)),
                                           EnvironmentVariableTarget.User);
        // Explorer, and terminals it starts from now on, pick the new PATH up.
        SendMessageTimeout(new IntPtr(0xFFFF), 0x001A, IntPtr.Zero, "Environment", 0x0002, 5000, out _);
    }

    static IEnumerable<string> Entries() =>
        (Environment.GetEnvironmentVariable("Path", EnvironmentVariableTarget.User) ?? "")
            .Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    static bool SameFolder(string a, string b) =>
        string.Equals(Environment.ExpandEnvironmentVariables(a).TrimEnd('\\'),
                      Environment.ExpandEnvironmentVariables(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, string lParam, uint flags,
                                            uint timeout, out IntPtr result);
}
