import SwiftUI

/// One provider's share of a period's estimated spend.
public struct CostSlice: Identifiable, Equatable, Sendable {
    public let style: ProviderStyle
    public let dollars: Double
    public let tokens: Int
    public var id: String { style.name }

    public init(style: ProviderStyle, dollars: Double, tokens: Int) {
        self.style = style
        self.dollars = dollars
        self.tokens = tokens
    }
}

public struct CostPeriodData: Identifiable, Equatable, Sendable {
    public let title: String
    public let slices: [CostSlice]
    /// Most expensive models in the period.
    public let models: [CostModelLine]
    public var id: String { title }
    public var total: Double { slices.reduce(0) { $0 + $1.dollars } }
    public var tokens: Int { slices.reduce(0) { $0 + $1.tokens } }

    public init(title: String, slices: [CostSlice], models: [CostModelLine] = []) {
        self.title = title
        self.slices = slices
        self.models = models
    }
}

/// One model's share of a period or day.
public struct CostModelLine: Identifiable, Equatable, Sendable {
    public let style: ProviderStyle
    public let model: String
    public let dollars: Double
    public let tokens: Int
    public var id: String { style.id + "/" + model }

    public init(style: ProviderStyle, model: String, dollars: Double, tokens: Int) {
        self.style = style
        self.model = model
        self.dollars = dollars
        self.tokens = tokens
    }
}

/// One day of the 30-day history.
public struct CostDayData: Identifiable, Equatable, Sendable {
    public let date: Date
    public let slices: [CostSlice]
    public let models: [CostModelLine]
    public var id: Date { date }
    public var total: Double { slices.reduce(0) { $0 + $1.dollars } }

    public init(date: Date, slices: [CostSlice], models: [CostModelLine]) {
        self.date = date
        self.slices = slices
        self.models = models
    }
}

/// Estimated spend: a period switcher, a ring of provider shares with the
/// total in the middle, and a legend.
public struct CostCardView: View {
    let periods: [CostPeriodData]
    let days: [CostDayData]
    let isLoading: Bool
    let note: String
    @AppStorage("costPeriod") private var selectedTitle = "Today"
    @AppStorage("costHistoryShown") private var showsHistory = false
    @State private var hoveredDay: Date?

    public init(periods: [CostPeriodData], days: [CostDayData] = [], isLoading: Bool, note: String) {
        self.periods = periods
        self.days = days
        self.isLoading = isLoading
        self.note = note
    }

    private var selected: CostPeriodData? {
        periods.first { $0.title == selectedTitle } ?? periods.first
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Cost")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(note)
                Spacer(minLength: 8)
                periodSwitcher
                if !days.isEmpty {
                    Button {
                        withAnimation(.smooth(duration: 0.25)) { showsHistory.toggle() }
                    } label: {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(showsHistory ? Color.accentColor : Color.secondary)
                            .frame(width: 22, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showsHistory ? "Hide daily history" : "Show daily history and top models")
                }
            }
            HStack(spacing: 16) {
                CostRing(slices: selected?.slices ?? [], total: selected?.total ?? 0, isLoading: isLoading)
                    .frame(width: 92, height: 92)
                legend
            }
            if showsHistory, !days.isEmpty {
                history
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .panelCard()
    }

    /// 30 days of stacked bars; hovering a day swaps the model list for
    /// that day's.
    private var history: some View {
        let peak = max(days.map(\.total).max() ?? 0, 0.01)
        let hovered = days.first { $0.date == hoveredDay }
        return VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.6)
            HStack(alignment: .firstTextBaseline) {
                Text(hovered.map { $0.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? "Last 30 days")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(CostFormat.dollars(hovered?.total ?? days.reduce(0) { $0 + $1.total }))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(days) { day in
                    VStack(spacing: 0) {
                        ForEach(day.slices.reversed()) { slice in
                            Rectangle()
                                .fill(slice.style.accent)
                                .frame(height: max(0, 46 * slice.dollars / peak))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .bottom)
                    .background(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(day.total > 0 ? 0 : 0.06)).frame(height: 2)
                    }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
                    .opacity(hoveredDay == nil || hoveredDay == day.date ? 1 : 0.45)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hoveredDay = day.date } else if hoveredDay == day.date { hoveredDay = nil }
                    }
                }
            }
            .frame(height: 46)
            .animation(.easeOut(duration: 0.12), value: hoveredDay)
            let models = hovered?.models ?? selected?.models ?? []
            if !models.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(hovered == nil ? "Top models · \(selected?.title ?? "")" : "Top models")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(models.prefix(4)) { line in
                        HStack(spacing: 6) {
                            Circle().fill(line.style.accent).frame(width: 6, height: 6)
                            Text(line.model)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            Text(CostFormat.tokens(line.tokens))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                            Text(CostFormat.dollars(line.dollars))
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .frame(minWidth: 48, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private var periodSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(periods) { period in
                let isSelected = period.title == selected?.title
                Button {
                    selectedTitle = period.title
                } label: {
                    Text(period.title)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(selected?.slices ?? []) { slice in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle()
                        .fill(slice.style.accent)
                        .frame(width: 8, height: 8)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(slice.style.name)
                            .font(.system(size: 12.5, weight: .medium))
                        Text(CostFormat.tokens(slice.tokens) + " tokens")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text(CostFormat.dollars(slice.dollars))
                        .font(.system(size: 12.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Donut of provider shares.
private struct CostRing: View {
    let slices: [CostSlice]
    let total: Double
    let isLoading: Bool

    private static let gap = 0.012

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.07), lineWidth: 13)
            let shares = shares
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                let (start, end) = shares[index]
                Circle()
                    .trim(from: start, to: max(start, end - (end - start > Self.gap * 2 ? Self.gap : 0)))
                    .stroke(slice.style.accent, style: StrokeStyle(lineWidth: 13, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                if isLoading && total == 0 {
                    ProgressView().controlSize(.small)
                } else {
                    Text(CostFormat.compactDollars(total))
                        .font(.system(size: 16, weight: .semibold))
                        .monospacedDigit()
                    Text("est.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Start and end of each slice along the ring, 0–1.
    private var shares: [(Double, Double)] {
        guard total > 0 else { return slices.map { _ in (0, 0) } }
        var cursor = 0.0
        return slices.map { slice in
            let start = cursor
            cursor += slice.dollars / total
            return (start, cursor)
        }
    }
}

public enum CostFormat {
    /// "$42.64", "$1.14K".
    public static func dollars(_ value: Double) -> String {
        value >= 1000 ? String(format: "$%.2fK", value / 1000) : String(format: "$%.2f", value)
    }

    /// "$43", "$1.4K" — fits the ring's hole.
    public static func compactDollars(_ value: Double) -> String {
        if value >= 1000 { return String(format: "$%.1fK", value / 1000) }
        return value < 10 && value > 0 ? String(format: "$%.2f", value) : String(format: "$%.0f", value)
    }

    /// "950", "12.4K", "118.7M", "3.5B".
    public static func tokens(_ value: Int) -> String {
        let number = Double(value)
        switch number {
        case 1e9...: return String(format: "%.1fB", number / 1e9)
        case 1e6...: return String(format: "%.1fM", number / 1e6)
        case 1e3...: return String(format: "%.1fK", number / 1e3)
        default: return "\(value)"
        }
    }
}
