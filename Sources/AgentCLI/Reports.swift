import Foundation
import ClaudeProfilesCore
import CodexProfilesCore

/// One usage window, as of now: used share and when it resets.
struct WindowReport: Equatable {
    var usedPercent: Double
    var resetsAt: Date?

    /// A window that has reset since Claude last looked is empty again, with
    /// its next reset unknown.
    init(_ window: ProfileUsage.Window, now: Date) {
        if window.expired(at: now) {
            self.init(usedPercent: 0, resetsAt: nil)
        } else {
            self.init(usedPercent: min(100, max(0, window.percent)), resetsAt: window.resetsAt)
        }
    }

    init(_ window: UsageWindow) {
        self.init(usedPercent: window.usedPercent, resetsAt: window.resetAt)
    }

    init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    var json: [String: Any] { ["usedPercent": usedPercent, "resetsAt": orNull(resetsAt.map(isoDate))] }

    func text(_ label: String, now: Date) -> String {
        var text = "\(label) \(Int(usedPercent.rounded()))% used"
        if let resetsAt, resetsAt > now {
            text += ", resets in \(UsageWindow.compactDuration(resetsAt.timeIntervalSince(now)))"
        }
        return text
    }
}

/// Usage of a Claude account as Claude Desktop last fetched it.
struct ClaudeUsageReport: Equatable {
    struct Scoped: Equatable {
        var name: String
        var window: WindowReport
    }

    var session: WindowReport?
    var weekly: WindowReport?
    /// Weekly windows that cover only some models ("Sonnet", "Opus").
    var scoped: [Scoped]
    var extraUsage: ProfileUsage.ExtraUsage?
    var asOf: Date

    init(_ usage: ProfileUsage, now: Date) {
        session = usage.fiveHour.map { WindowReport($0, now: now) }
        weekly = usage.sevenDay.map { WindowReport($0, now: now) }
        scoped = usage.scoped.map { Scoped(name: $0.name, window: WindowReport($0.window, now: now)) }
        extraUsage = usage.extraUsage
        asOf = usage.asOf
    }

    var json: [String: Any] {
        [
            "session": orNull(session?.json),
            "weekly": orNull(weekly?.json),
            "scoped": scoped.map { $0.window.json.merging(["name": $0.name]) { _, name in name } },
            "extraUsage": orNull(extraUsage.map {
                ["used": $0.used, "limit": orNull($0.limit), "currency": $0.currency] as [String: Any]
            }),
            "asOf": isoDate(asOf),
        ]
    }

    /// Notes how old the numbers are once Claude hasn't looked for an hour.
    func text(now: Date) -> String {
        var parts = [session?.text("session", now: now), weekly?.text("weekly", now: now)].compactMap { $0 }
        if parts.isEmpty { parts.append("no usage seen yet") }
        let age = now.timeIntervalSince(asOf)
        if age >= 3600 { parts.append("as of \(UsageWindow.compactDuration(age)) ago") }
        return parts.joined(separator: " · ")
    }
}

struct CodexAccountReport: Equatable {
    var id: String
    var name: String
    var email: String?
    var active: Bool

    init(_ profile: Profile, active: Bool) {
        id = profile.id.uuidString
        name = profile.displayName
        email = profile.identity?.email
        self.active = active
    }

    var json: [String: Any] { ["id": id, "name": name, "email": orNull(email), "active": active] }
}

struct CodexUsageReport {
    var account: CodexAccountReport?
    /// What to call a login that matches no saved account.
    var fallbackName: String
    var usage: CodexUsage

    var json: [String: Any] {
        [
            "account": orNull(account?.json),
            "plan": orNull(usage.planType),
            "limitReached": orNull(usage.limitReached),
            "session": orNull(usage.primary.map { WindowReport($0).json }),
            "weekly": orNull(usage.secondary.map { WindowReport($0).json }),
            // Model-specific windows, such as Codex Spark's.
            "additional": usage.additional.map { WindowReport($0.window).json.merging(["name": $0.name]) { _, name in name } },
            "fetchedAt": isoDate(usage.fetchedAt),
        ]
    }

    func text(now: Date) -> String {
        var name = account?.name ?? fallbackName
        if let plan = usage.planType, !plan.isEmpty { name += " (\(plan))" }
        var parts = [
            usage.primary.map { WindowReport($0).text("session", now: now) },
            usage.secondary.map { WindowReport($0).text("weekly", now: now) },
        ].compactMap { $0 }
        if usage.limitReached == true { parts.insert("limit reached", at: 0) }
        return name + ": " + (parts.isEmpty ? "no limits reported" : parts.joined(separator: " · "))
    }
}

func isoDate(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

/// A saved Codex account's usage, or why there is none.
struct SavedCodexUsage {
    var profile: Profile
    var usage: CodexUsage?
    var error: String?

    var json: [String: Any] {
        let report = usage.map { CodexUsageReport(account: nil, fallbackName: "", usage: $0).json }
        return [
            "account": CodexAccountReport(profile, active: false).json,
            "usage": orNull(report?.filter { $0.key != "account" }),
            "error": orNull(error),
        ]
    }

    func text(now: Date) -> String {
        if let usage {
            return CodexUsageReport(account: CodexAccountReport(profile, active: false), fallbackName: "", usage: usage)
                .text(now: now)
        }
        return profile.displayName + ": " + (error ?? "no usage")
    }
}
