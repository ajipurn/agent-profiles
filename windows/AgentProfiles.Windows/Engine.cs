using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace AgentProfiles.Windows;

/// <summary>A failure the engine reported: its <c>{"error": "…"}</c>, or what it printed.</summary>
public sealed class EngineException(string message) : Exception(message);

/// <summary>
/// Runs agent-profiles.exe, the Swift engine shipped next to this app, one
/// command at a time: two runs never write the profile stores at once.
/// </summary>
public sealed class Engine
{
    static readonly JsonSerializerOptions Options = new() { PropertyNameCaseInsensitive = true };
    readonly SemaphoreSlim gate = new(1, 1);

    /// <summary>AGENT_PROFILES_ENGINE overrides where it is, for development.</summary>
    public string Executable { get; } =
        Environment.GetEnvironmentVariable("AGENT_PROFILES_ENGINE") is { Length: > 0 } custom
            ? custom
            : Path.Combine(AppContext.BaseDirectory, "agent-profiles.exe");

    public async Task<T> RunAsync<T>(params string[] arguments)
    {
        var output = await RunRawAsync(arguments.Append("--json"), TimeSpan.FromSeconds(90));
        return JsonSerializer.Deserialize<T>(output, Options)
            ?? throw new EngineException("The engine answered with nothing.");
    }

    /// <summary>A command whose JSON answer isn't needed (switches, setup).</summary>
    public Task RunAsync(params string[] arguments) =>
        RunRawAsync(arguments.Append("--json"), TimeSpan.FromMinutes(2));

    async Task<string> RunRawAsync(IEnumerable<string> arguments, TimeSpan timeout)
    {
        await gate.WaitAsync();
        try
        {
            if (!File.Exists(Executable))
                throw new EngineException($"agent-profiles.exe is missing from {Path.GetDirectoryName(Executable)}.");
            var start = new ProcessStartInfo(Executable)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            foreach (var argument in arguments) start.ArgumentList.Add(argument);
            using var process = Process.Start(start) ?? throw new EngineException("The engine could not start.");
            var output = process.StandardOutput.ReadToEndAsync();
            var errors = process.StandardError.ReadToEndAsync();
            using var cancel = new CancellationTokenSource(timeout);
            try
            {
                await process.WaitForExitAsync(cancel.Token);
            }
            catch (OperationCanceledException)
            {
                try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                throw new EngineException("The engine took too long to answer.");
            }
            var text = await output;
            if (process.ExitCode != 0)
                throw new EngineException(ErrorIn(text) ?? FirstLine(await errors) ?? $"The engine failed ({process.ExitCode}).");
            return text;
        }
        finally
        {
            gate.Release();
        }
    }

    static string? ErrorIn(string output)
    {
        try
        {
            using var document = JsonDocument.Parse(output);
            return document.RootElement.TryGetProperty("error", out var error) ? error.GetString() : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    static string? FirstLine(string text) =>
        text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(line => line.StartsWith("agent-profiles: ") ? line["agent-profiles: ".Length..] : line)
            .FirstOrDefault();
}
