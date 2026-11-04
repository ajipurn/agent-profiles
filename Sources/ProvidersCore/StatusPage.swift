import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An open incident or degradation on a provider's Statuspage.
public struct StatusIncident: Equatable, Sendable {
    public enum Level: String, Sendable { case minor, major, critical, maintenance }

    public var level: Level
    /// Statuspage's own summary ("Partial System Outage") or the newest
    /// incident's name.
    public var title: String
    public var pageURL: URL

    public var isMajor: Bool { level == .major || level == .critical }
}

/// Reads `<base>/api/v2/summary.json` — public, no credentials.
public enum StatusPage {
    public static func fetch(_ base: URL, session: URLSession) async throws -> StatusIncident? {
        let url = base.appendingPathComponent("api/v2/summary.json")
        let object = try await ProviderHTTP.object(ProviderHTTP.request(url),
                                                   in: ProviderEnvironment(session: session))
        return parse(object, base: base)
    }

    static func parse(_ object: [String: Any], base: URL) -> StatusIncident? {
        let status = object["status"] as? [String: Any]
        let indicator = ProviderJSON.string(status?["indicator"]) ?? "none"
        let incidents = (object["incidents"] as? [[String: Any]] ?? [])
            .filter { ProviderJSON.string($0["status"]) != "resolved" && ProviderJSON.string($0["status"]) != "postmortem" }
        let maintenance = (object["scheduled_maintenances"] as? [[String: Any]] ?? [])
            .filter { ProviderJSON.string($0["status"]) == "in_progress" }
        let level: StatusIncident.Level
        switch indicator {
        case "minor": level = .minor
        case "major": level = .major
        case "critical": level = .critical
        case "maintenance": level = .maintenance
        default:
            guard !incidents.isEmpty || !maintenance.isEmpty else { return nil }
            level = incidents.isEmpty ? .maintenance : .minor
        }
        let page = (object["page"] as? [String: Any]).flatMap { ProviderJSON.string($0["url"]) }.flatMap(URL.init(string:)) ?? base
        let name = ProviderJSON.string((incidents.first ?? maintenance.first)?["name"])
        let title = name ?? ProviderJSON.string(status?["description"]) ?? "Service disruption"
        return StatusIncident(level: level, title: title, pageURL: page)
    }
}
