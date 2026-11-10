import SwiftUI

/// Every provider in one list: logo, account, its first two limits as
/// stacked meters, and the soonest reset. Clicking a row opens its tab.
public struct OverviewView: View {
    public struct Row: Identifiable {
        public let id: String
        public let card: UsageCardModel

        public init(id: String, card: UsageCardModel) {
            self.id = id
            self.card = card
        }

        /// The lowest remaining share across its limits, for ordering.
        public var tightest: Double? { card.limits.compactMap(\.remaining).min() }
    }

    let rows: [Row]
    let onSelect: (String) -> Void

    public init(rows: [Row], onSelect: @escaping (String) -> Void) {
        self.rows = rows
        self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Closest to running out first")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    OverviewRow(row: row) { onSelect(row.id) }
                    if row.id != rows.last?.id { Divider().opacity(0.5).padding(.leading, 44) }
                }
            }
            .padding(4)
            .panelCard()
        }
    }
}

private struct OverviewRow: View {
    let row: OverviewView.Row
    let action: () -> Void
    @State private var hovering = false
    @AppStorage(UsageDisplay.hidePersonalKey) private var hidePersonal = false
    @AppStorage(UsageDisplay.showsUsedKey) private var showsUsed = false

    var body: some View {
        let card = row.card
        Button(action: action) {
            HStack(spacing: 10) {
                ProviderLogo(card.provider, size: 15)
                    .foregroundStyle(card.provider.accent)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(card.provider.accent.opacity(0.13)))
                    .overlay(alignment: .topTrailing) {
                        if card.incident != nil {
                            Circle().fill(Color.orange).frame(width: 7, height: 7)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.provider.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let reset {
                            Text(reset)
                                .monospacedDigit()
                                .fixedSize()
                            if !subtitle.isEmpty { Text("·").foregroundStyle(.tertiary) }
                        }
                        Text(subtitle)
                            .foregroundStyle(card.noticeTone == .error && card.limits.isEmpty ? Color.red : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if card.limits.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .trailing, spacing: 5) {
                        ForEach(card.limits.prefix(2)) { limit in
                            HStack(spacing: 6) {
                                Text(short(limit.title))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(width: 30, alignment: .trailing)
                                UsageBar(remaining: limit.remaining, tint: UsageTint.color(limit.level), height: 4)
                                    .frame(width: 50)
                                Text(UsageFormat.compact(limit.remaining, showsUsed: showsUsed))
                                    .font(.system(size: 10.5, weight: .medium))
                                    .monospacedDigit()
                                    .foregroundStyle(UsageTint.text(limit.level))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .frame(minWidth: 34, alignment: .trailing)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .opacity(card.isStale ? 0.7 : 1)
        .help(tooltip)
    }

    private var subtitle: String {
        let card = row.card
        if card.limits.isEmpty, let text = card.notice ?? card.placeholder { return text }
        return card.account.map { UsageFormat.personal($0, hide: hidePersonal) } ?? card.badge ?? ""
    }

    /// The soonest reset of the two limits shown, as "↻ 1h 59m".
    private var reset: String? {
        guard let date = row.card.limits.prefix(2).compactMap(\.resetsAt).filter({ $0 > Date() }).min(),
              let text = UsageFormat.resetText(date, clock: UsageDisplay.resetAsClock) else { return nil }
        return "↻ " + text.replacingOccurrences(of: "Resets in ", with: "").replacingOccurrences(of: "Resets ", with: "")
    }

    private var tooltip: String {
        row.card.limits.map { limit in
            var line = "\(limit.fullTitle): \(UsageFormat.percent(limit.remaining)) left"
            if let reset = UsageFormat.resetText(limit.resetsAt, clock: UsageDisplay.resetAsClock) {
                line += " · " + reset.lowercased()
            }
            return line
        }.joined(separator: "\n")
    }

    /// Short labels for the meters: "5h", "Wk", "Mo", "Day", else the first word.
    private func short(_ title: String) -> String {
        switch title {
        case "Session", "5h limit": "5h"
        case "Weekly", "Weekly limit": "Wk"
        case "Monthly": "Mo"
        case "Daily": "Day"
        default: String(title.split(separator: " ").first ?? Substring(title))
        }
    }
}
