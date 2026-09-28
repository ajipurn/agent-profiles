import Foundation
import ClaudeProfilesCore

/// `percent` in ProfileUsage is Claude's *used* share; everything shown here
/// is the *remaining* share. An expired window has reset since Claude last
/// looked, so the account is back to 100%.
extension ProfileUsage.Window {
    var remainingPercent: Int { remainingPercent(at: Date()) }

    func remainingPercent(at now: Date) -> Int {
        expired(at: now) ? 100 : max(0, min(100, 100 - Int(percent)))
    }
}

extension ProfileUsage {
    /// Remaining share of the 5-hour window.
    var fiveHourRemaining: Int? { fiveHour?.remainingPercent }

    var tooltip: String {
        let rel = RelativeDateTimeFormatter()
        var lines: [String] = []
        func line(_ name: String, _ w: Window?) {
            guard let w else { return }
            var text = "\(name): \(w.remainingPercent)% left"
            if !w.expired, let resetsAt = w.resetsAt {
                text += " — resets \(rel.localizedString(for: resetsAt, relativeTo: Date()))"
            }
            lines.append(text)
        }
        line("Session (5h)", fiveHour)
        line("Week", sevenDay)
        lines.append("From Claude's own last check, \(rel.localizedString(for: asOf, relativeTo: Date()))")
        return lines.joined(separator: "\n")
    }
}
