import SwiftUI
import Charts
import UsageHistoryCore

struct HistoryAccount: Equatable {
    var id: String
    var name: String
}

/// Settings → History: how each account's limits filled over the last week or
/// month, from the readings the app kept while it ran.
struct HistoryView: View {
    let history: UsageHistory
    /// The provider's accounts in the app's own order; colors follow it.
    let accounts: @MainActor (UsageSample.Provider) -> [HistoryAccount]

    @AppStorage("historyProvider") private var provider: UsageSample.Provider = .claude
    @AppStorage("historyWindow") private var window: UsageWindowKind = .weekly
    @AppStorage("historyDays") private var days = 7
    @State private var samples: [UsageSample] = []
    @State private var hovered: Date?

    /// A line breaks where no reading came for this long.
    private static let gap: TimeInterval = 3600

    private struct Line: Identifiable {
        var account: HistoryAccount
        var color: Color
        /// Every reading in the range, for the table and the tooltip.
        var all: AccountHistory
        /// Fewer readings, the highest kept, for drawing.
        var drawn: AccountHistory
        var id: String { account.id }
    }

    /// One drawn reading; `run` tells the chart where a line breaks.
    private struct Point: Identifiable {
        var id: String
        var at: Date
        var value: Double
        var run: String
        var name: String
    }

    private struct TooltipRow: Identifiable {
        var line: Line
        var value: Double
        var id: String { line.id }
    }

    var body: some View {
        let lines = makeLines()
        VStack(alignment: .leading, spacing: 16) {
            controls
            if lines.isEmpty {
                ContentUnavailableView {
                    Label("No history yet", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("Agent Profiles keeps a reading every ten minutes at most while it runs and "
                         + (provider == .claude ? "Claude Desktop" : "Codex") + " reports usage. Check back in a few hours.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart(lines)
                    .frame(minHeight: 240)
                table(lines)
            }
            Text("The used share of each limit, as Claude and Codex reported it. Gaps are times nothing was reported. Readings stay on this Mac for 30 days.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            while !Task.isCancelled {
                samples = await history.samples(since: Date().addingTimeInterval(-UsageHistory.retention))
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Provider", selection: $provider) {
                Text("Claude").tag(UsageSample.Provider.claude)
                Text("Codex").tag(UsageSample.Provider.codex)
            }
            Picker("Limit", selection: $window) {
                Text("Weekly").tag(UsageWindowKind.weekly)
                Text("Session").tag(UsageWindowKind.session)
            }
            Picker("Range", selection: $days) {
                Text("7 Days").tag(7)
                Text("30 Days").tag(30)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var start: Date { Date().addingTimeInterval(-Double(days) * 86_400) }

    /// One line per account with readings in range. Colors go by the
    /// account's place in the app's order, not by what the range shows, so
    /// changing the range never repaints an account.
    @MainActor private func makeLines() -> [Line] {
        let known = accounts(provider)
        let names = Dictionary(known.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let everyAccount = AccountHistory.group(samples, provider: provider, order: known.map(\.id)).map(\.account)
        let palette = known.map(\.id) + everyAccount.filter { names[$0] == nil }
        let since = start
        return AccountHistory.group(samples.filter { $0.at >= since }, provider: provider, order: palette)
            .map { group in
                Line(account: HistoryAccount(id: group.account, name: names[group.account] ?? removedName(group.account)),
                     color: HistoryPalette.color(palette.firstIndex(of: group.account) ?? palette.count),
                     all: group,
                     drawn: group.thinned(window, every: days > 7 ? 3600 : 1200))
            }
    }

    /// A Claude profile keeps its name; a removed Codex account is told
    /// apart by the start of its id.
    private func removedName(_ account: String) -> String {
        provider == .claude ? account : "Removed account " + account.prefix(4)
    }

    private func points(_ lines: [Line]) -> [Point] {
        var points: [Point] = []
        for line in lines {
            for (run, samples) in line.drawn.segments(gap: Self.gap).enumerated() {
                for sample in samples {
                    guard let value = window.value(sample) else { continue }
                    let key = "\(line.id)/\(run)"
                    points.append(Point(id: "\(key)/\(sample.at.timeIntervalSince1970)", at: sample.at, value: value,
                                        run: key, name: line.account.name))
                }
            }
        }
        return points
    }

    private func chart(_ lines: [Line]) -> some View {
        Chart {
            ForEach(points(lines)) { point in
                LineMark(x: .value("Time", point.at), y: .value("Used", point.value), series: .value("Run", point.run))
                    .foregroundStyle(by: .value("Account", point.name))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let hovered {
                RuleMark(x: .value("Time", hovered))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(lines, at: hovered)
                    }
            }
        }
        .chartForegroundStyleScale(domain: lines.map(\.account.name), range: lines.map(\.color))
        .chartYScale(domain: 0...100)
        .chartXScale(domain: start...Date())
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Double.self) { Text(Self.percent(percent)) }
                }
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plot = proxy.plotFrame else { return }
                            hovered = proxy.value(atX: location.x - geometry[plot].origin.x, as: Date.self)
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
    }

    private func tooltip(_ lines: [Line], at date: Date) -> some View {
        let rows = lines.compactMap { line in
            line.all.value(window, at: date, within: Self.gap).map { TooltipRow(line: line, value: $0) }
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                .foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("No reading").foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    Circle().fill(row.line.color).frame(width: 8, height: 8)
                    Text(row.line.account.name).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(Self.percent(row.value)).monospacedDigit()
                }
            }
        }
        .font(.caption)
        .padding(8)
        .frame(width: 210)
        .background(.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.separator))
    }

    /// The numbers behind the lines, so no value depends on telling colors apart.
    private func table(_ lines: [Line]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
            GridRow {
                Text("Account")
                Text("Latest").gridColumnAlignment(.trailing)
                Text("Peak").gridColumnAlignment(.trailing)
                Text("Reached 100%").gridColumnAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
            ForEach(lines) { line in
                GridRow {
                    HStack(spacing: 6) {
                        Circle().fill(line.color).frame(width: 8, height: 8)
                        Text(line.account.name).lineLimit(1)
                    }
                    Text(Self.percent(line.all.latest.flatMap(window.value)))
                    Text(Self.percent(line.all.peak(window)))
                    Text(Self.times(line.all.timesFull(window)))
                }
                .monospacedDigit()
            }
        }
    }

    static func percent(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))%" } ?? "–"
    }

    static func times(_ count: Int) -> String {
        count == 0 ? "–" : "\(count)×"
    }
}

/// The reference categorical order, in light and dark steps validated for
/// lines in both modes. Colors go to accounts in order and never cycle: a
/// ninth account is drawn gray, and the table still names it.
enum HistoryPalette {
    static let steps: [(light: UInt32, dark: UInt32)] = [
        (0x2A78D6, 0x3987E5), // blue
        (0xEB6834, 0xD95926), // orange
        (0x1BAF7A, 0x199E70), // aqua
        (0xEDA100, 0xC98500), // yellow
        (0xE87BA4, 0xD55181), // magenta
        (0x008300, 0x008300), // green
        (0x4A3AA7, 0x9085E9), // violet
        (0xE34948, 0xE66767), // red
    ]

    static func color(_ index: Int) -> Color {
        guard steps.indices.contains(index) else { return .gray }
        let step = steps[index]
        return Color(nsColor: NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? step.dark : step.light)
        })
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
