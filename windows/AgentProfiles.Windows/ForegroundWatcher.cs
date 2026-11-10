using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace AgentProfiles.Windows;

/// <summary>
/// Tells which provider's app came to the front: Claude Desktop, ChatGPT or
/// Codex, Antigravity. Other apps (terminals included) say nothing, so the
/// tray icon keeps the last one, as on the Mac.
/// </summary>
public sealed class ForegroundWatcher : IDisposable
{
    const uint EventSystemForeground = 0x0003;
    const uint OutOfContext = 0x0000;

    delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId, uint thread, uint time);

    readonly WinEventProc callback;
    readonly IntPtr hook;

    public event Action<string>? ProviderActivated;

    public ForegroundWatcher()
    {
        callback = OnForeground; // kept alive as long as the hook
        hook = SetWinEventHook(EventSystemForeground, EventSystemForeground, IntPtr.Zero, callback, 0, 0, OutOfContext);
    }

    void OnForeground(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId, uint thread, uint time)
    {
        if (ProviderFor(window) is { } provider) ProviderActivated?.Invoke(provider);
    }

    public static string? ProviderFor(IntPtr window)
    {
        GetWindowThreadProcessId(window, out var pid);
        if (pid == 0 || pid == Environment.ProcessId) return null;
        string? path;
        try
        {
            using var process = Process.GetProcessById((int)pid);
            path = process.MainModule?.FileName;
        }
        catch (Exception exception) when (exception is ArgumentException or InvalidOperationException
                                              or System.ComponentModel.Win32Exception)
        {
            return null; // gone, or another user's (elevated) process
        }
        if (path is null) return null;
        var file = Path.GetFileName(path).ToLowerInvariant();
        // Claude Code's claude.exe shares the name; only Claude Desktop's install counts.
        if (file == "claude.exe" && (path.Contains(@"\AnthropicClaude\", StringComparison.OrdinalIgnoreCase)
                                     || path.Contains(@"\WindowsApps\", StringComparison.OrdinalIgnoreCase)))
            return "claude";
        if (file is "chatgpt.exe" or "codex.exe") return "codex";
        if (file == "antigravity.exe") return "antigravity";
        return null;
    }

    [DllImport("user32.dll")]
    static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr module, WinEventProc callback,
                                         uint processId, uint threadId, uint flags);

    [DllImport("user32.dll")]
    static extern bool UnhookWinEvent(IntPtr hook);

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    public void Dispose()
    {
        if (hook != IntPtr.Zero) UnhookWinEvent(hook);
    }
}
