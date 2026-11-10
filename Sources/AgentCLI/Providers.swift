import Foundation
import ProvidersCore

/// Usage of the providers beyond Claude and Codex (Gemini, Antigravity,
/// Copilot, …), read the way the app's More Providers do: from the sign-in
/// each provider's own tool keeps, never written back.
extension Commands {
    /// `providers`: every provider and whether it is signed in on this
    /// computer. `providers usage [id …]`: usage of those, or of every
    /// signed-in one, fetched now.
    func providers(_ words: [String]) async throws {
        let environment = ProviderEnvironment(home: context.home)
        let all = ProviderRegistry.all
        switch words.first {
        case nil:
            let rows = all.map { ($0, $0.isSignedIn(in: environment)) }
            if json {
                return emit(rows.map { provider, signedIn in
                    ["id": provider.id, "name": provider.name, "brandHex": provider.brandHex, "signedIn": signedIn,
                     "appBundleIDs": provider.appBundleIDs] as [String: Any]
                })
            }
            let width = all.map(\.id.count).max() ?? 0
            context.output(rows.map { provider, signedIn in
                provider.id.padding(toLength: width + 2, withPad: " ", startingAt: 0)
                    + (signedIn ? "signed in" : "not signed in")
            }.joined(separator: "\n"))
        case "usage":
            let ids = Array(words.dropFirst())
            if let unknown = ids.first(where: { id in !all.contains { $0.id == id } }) {
                throw CLIError.usage("unknown provider \(unknown); use one of " + all.map(\.id).joined(separator: ", "))
            }
            let chosen = ids.isEmpty ? all.filter { $0.isSignedIn(in: environment) } : all.filter { ids.contains($0.id) }
            let reports = await Self.fetch(chosen, in: environment)
            if json { return emit(reports.map(\.json)) }
            context.output(reports.isEmpty ? "No provider is signed in." : reports.map { $0.text(now: Date()) }.joined(separator: "\n"))
        case let word?:
            throw CLIError.usage("unknown providers command \(word); use providers or providers usage [id …]")
        }
    }

    /// All at once, reported in the order asked for.
    static func fetch(_ providers: [any UsageProvider], in environment: ProviderEnvironment) async -> [ProviderReport] {
        await withTaskGroup(of: (Int, ProviderReport).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    do {
                        return (index, ProviderReport(provider: provider, snapshot: try await provider.fetch(in: environment)))
                    } catch {
                        return (index, ProviderReport(provider: provider, error: error.localizedDescription))
                    }
                }
            }
            var reports: [(Int, ProviderReport)] = []
            for await report in group { reports.append(report) }
            return reports.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

struct ProviderReport {
    var provider: any UsageProvider
    var snapshot: ProviderSnapshot?
    var error: String?

    var json: [String: Any] {
        func window(_ window: ProviderWindow) -> [String: Any] {
            ["title": window.title, "group": orNull(window.group), "usedPercent": window.usedPercent,
             "resetsAt": orNull(window.resetsAt.map(isoDate)), "windowSeconds": orNull(window.windowSeconds)]
        }
        return [
            "id": provider.id,
            "name": provider.name,
            "brandHex": provider.brandHex,
            "account": orNull(snapshot?.account),
            "plan": orNull(snapshot?.plan),
            "windows": snapshot?.windows.map(window) ?? [],
            // The two the menu bar icon shows: top bar, then bottom bar.
            "primary": snapshot?.primaryWindows.map(window) ?? [],
            "details": snapshot?.details.map {
                ["title": $0.title, "value": $0.value, "usedPercent": orNull($0.usedPercent)] as [String: Any]
            } ?? [],
            "fetchedAt": orNull(snapshot.map { isoDate($0.fetchedAt) }),
            "error": orNull(error),
        ]
    }

    func text(now: Date) -> String {
        var head = provider.name
        if let plan = snapshot?.plan { head += " (\(plan))" }
        if let account = snapshot?.account { head += " " + account }
        guard let snapshot else { return head + ": " + (error ?? "no usage") }
        var lines = [head]
        for window in snapshot.windows {
            let title = window.group.map { "\($0) · \(window.title)" } ?? window.title
            var line = "  \(title): \(Int(window.usedPercent.rounded()))% used"
            if let resetsAt = window.resetsAt, resetsAt > now {
                line += ", resets in \(Self.duration(resetsAt.timeIntervalSince(now)))"
            }
            lines.append(line)
        }
        lines += snapshot.details.map { "  \($0.title): \($0.value)" }
        if let error { lines.append("  " + error) }
        return lines.joined(separator: "\n")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes >= 1440 { return "\(minutes / 1440)d \(minutes % 1440 / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(max(1, minutes))m"
    }
}
