import SwiftUI
import AppKit

/// A thin capsule filled by the remaining share of a limit, or by the used
/// share when Settings says so.
public struct UsageBar: View {
    let remaining: Double?
    let tint: Color
    var height: CGFloat
    /// Where an even burn would be now (as a remaining share); a small tick.
    var evenTick: Double?
    @AppStorage(UsageDisplay.showsUsedKey) private var showsUsed = false

    public init(remaining: Double?, tint: Color, height: CGFloat = 6, evenTick: Double? = nil) {
        self.remaining = remaining
        self.tint = tint
        self.height = height
        self.evenTick = evenTick
    }

    public var body: some View {
        GeometryReader { proxy in
            let value = remaining.map { showsUsed ? 100 - $0 : $0 } ?? 0
            let share = min(max(value / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(PanelColors.track)
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.8), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: share > 0 ? max(height, proxy.size.width * share) : 0)
            }
            .frame(width: proxy.size.width, height: height)
            // An overlay, so the taller tick never stretches the bar itself.
            .overlay(alignment: .leading) {
                if let evenTick {
                    let tick = showsUsed ? 100 - evenTick : evenTick
                    Capsule()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 2, height: height + 4)
                        .offset(x: proxy.size.width * min(max(tick / 100, 0), 1) - 1)
                }
            }
            .animation(.smooth(duration: 0.35), value: share)
        }
        .frame(height: height)
        .accessibilityLabel(UsageFormat.share(remaining, showsUsed: showsUsed))
    }
}

/// The selected provider: title, plan and account, any notice, then one
/// card of limit rows and detail lines.
public struct UsageCardView: View {
    let model: UsageCardModel
    @AppStorage(UsageDisplay.hidePersonalKey) private var hidePersonal = false

    public init(model: UsageCardModel) {
        self.model = model
    }

    public var body: some View {
        // Countdowns and pace depend on the clock, not just the model.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 10) {
                header
                if let incident = model.incident {
                    IncidentView(incident: incident)
                }
                if let notice = model.notice {
                    NoticeView(text: notice, tone: model.noticeTone)
                }
                if !model.limits.isEmpty || !model.details.isEmpty || model.placeholder != nil {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.limits.isEmpty, let placeholder = model.placeholder {
                            Text(placeholder)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(model.limits) { limit in
                            LimitRow(limit: limit, now: context.date)
                        }
                        if !model.details.isEmpty {
                            if !model.limits.isEmpty { Divider().opacity(0.6) }
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(model.details) { DetailRow(detail: $0) }
                            }
                        }
                    }
                    .padding(14)
                    .panelCard()
                }
            }
            .opacity(model.isStale ? 0.72 : 1)
            .animation(.smooth(duration: 0.25), value: model.limits.count)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderLogo(model.provider, size: 22)
                .foregroundStyle(model.provider.accent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(model.provider.accent.opacity(0.13)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 6) {
                    Text(model.provider.name)
                        .font(.system(size: 15, weight: .semibold))
                    if let badge = model.badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                let account = model.account.map { UsageFormat.personal($0, hide: hidePersonal) }
                let line = [account, model.subtitle].compactMap { $0 }.joined(separator: " · ")
                if !line.isEmpty {
                    Text(line)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let url = model.dashboardURL {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open \(model.provider.name) usage dashboard")
            }
        }
        .padding(.horizontal, 2)
    }
}

private struct IncidentView: View {
    let incident: UsageIncident

    var body: some View {
        let color: Color = incident.isMajor ? .red : PanelColors.warning
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.caption.weight(.semibold))
            Text(incident.title)
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let url = incident.url {
                Link("Status", destination: url)
                    .font(.caption.weight(.semibold))
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.12)))
    }
}

private struct NoticeView: View {
    let text: String
    let tone: UsageCardModel.Tone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.12)))
    }

    private var symbol: String {
        switch tone {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .info: .secondary
        case .warning: PanelColors.warning
        case .error: .red
        }
    }
}

/// "Extra usage        $12.40 of $50", with a thin bar when capped.
private struct DetailRow: View {
    let detail: UsageDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(detail.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(detail.value)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            if let used = detail.used {
                let left = 100 - used
                UsageBar(remaining: left, tint: UsageTint.color(UsageLimit(title: "", remaining: left).level), height: 4)
            }
        }
    }
}

private struct LimitRow: View {
    let limit: UsageLimit
    let now: Date
    @AppStorage(UsageDisplay.showsUsedKey) private var showsUsed = false
    @AppStorage(UsageDisplay.resetClockKey) private var resetAsClock = false

    var body: some View {
        let pace = limit.pace(now: now)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                paceNote(pace)
            }
            UsageBar(remaining: limit.remaining, tint: UsageTint.color(pace.verdict), height: 7,
                     evenTick: pace.verdict == .comfortable ? nil : pace.evenRemaining)
            HStack(alignment: .firstTextBaseline) {
                // Click either value to flip how every value reads.
                Button { showsUsed.toggle() } label: {
                    Text(UsageFormat.share(limit.remaining, showsUsed: showsUsed))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .buttonStyle(.plain)
                .help(showsUsed ? "Show what's left" : "Show what's used")
                Spacer(minLength: 8)
                if let reset = UsageFormat.resetText(limit.resetsAt, now: now, clock: resetAsClock) {
                    Button { resetAsClock.toggle() } label: {
                        Text(reset)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .buttonStyle(.plain)
                    .help(resetAsClock ? "Show as countdown" : "Show as clock time")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func paceNote(_ pace: UsagePace) -> some View {
        switch pace.verdict {
        case .comfortable:
            if let left = pace.projectedLeft {
                Text("~\(Int(left.rounded()))% left at reset")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .tight:
            if let left = pace.projectedLeft {
                Text("~\(max(1, Int(left.rounded())))% spare")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(PanelColors.warning)
            }
        case .over:
            Label(UsageFormat.limitText((limit.remaining ?? 0).rounded() <= 0 ? nil : pace.runsOutAt ?? limit.resetsAt, now: now),
                  systemImage: "flame.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.red)
                .labelStyle(.titleAndIcon)
        }
    }
}

/// One tint for every provider; only the verdict changes it.
public enum UsageTint {
    public static func color(_ verdict: UsagePace.Verdict) -> Color {
        switch verdict {
        case .comfortable: ProviderStyle.usageTint
        case .tight: .yellow
        case .over: .red
        }
    }

    /// Text in the verdict's color, dark enough to read on light panels.
    public static func text(_ verdict: UsagePace.Verdict) -> Color {
        switch verdict {
        case .comfortable: .secondary
        case .tight: PanelColors.warning
        case .over: .red
        }
    }
}

/// Panel colors that need a different shade per appearance.
public enum PanelColors {
    /// Yellow is unreadable as small text on a light panel; orange-brown there.
    public static let warning = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemYellow
            : NSColor(srgbRed: 0.72, green: 0.42, blue: 0, alpha: 1)
    })
    /// Empty part of a bar.
    public static let track = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.08)
    })
    /// Hairline around cards.
    public static let hairline = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.07)
            : NSColor.black.withAlphaComponent(0.06)
    })
}

/// One switchable account: initials, name, then its 5-hour and weekly
/// windows as two stacked meters (the menu bar icon's layout). Lights up on
/// hover; the tooltip spells out both resets.
public struct AccountRowView: View {
    let account: UsageAccount
    let tint: Color
    let isEnabled: Bool
    let isBest: Bool
    let action: () -> Void
    @State private var hovering = false
    @AppStorage(UsageDisplay.hidePersonalKey) private var hidePersonal = false

    public init(account: UsageAccount, tint: Color = .accentColor, isEnabled: Bool, isBest: Bool = false,
                action: @escaping () -> Void) {
        self.account = account
        self.tint = tint
        self.isEnabled = isEnabled
        self.isBest = isBest
        self.action = action
    }

    private var title: String { UsageFormat.personal(account.title, hide: hidePersonal) }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text(Self.initials(account.title))
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(tint.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if account.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8.5))
                                .foregroundStyle(Color.yellow)
                        }
                    }
                    if isBest {
                        Text("Most left")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.green)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 5) {
                    MiniMeter(label: "5h", limit: account.session)
                    MiniMeter(label: "Wk", limit: account.weekly)
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 9)
                    .opacity(hovering && isEnabled ? 1 : 0)
                    .offset(x: hovering && isEnabled ? 0 : -4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering && isEnabled ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(UsageFormat.percent(account.session?.remaining)) of session, \(UsageFormat.percent(account.weekly?.remaining)) of week left")
    }

    private var tooltip: String {
        func line(_ name: String, _ limit: UsageLimit?) -> String {
            guard let limit, let remaining = limit.remaining else { return "\(name): no data yet" }
            var text = "\(name): \(UsageFormat.percent(remaining)) left"
            if let reset = UsageFormat.resetText(limit.resetsAt, clock: UsageDisplay.resetAsClock) {
                text += " · \(reset.lowercased())"
            }
            return text
        }
        return [line("Session (5h)", account.session), line("Weekly", account.weekly)].joined(separator: "\n")
    }

    static func initials(_ name: String) -> String {
        let base = name.split(separator: "@").first.map(String.init) ?? name
        let words = base.split(whereSeparator: { " ._-".contains($0) })
        let letters = words.count > 1 ? words.prefix(2).compactMap(\.first) : Array(base.prefix(2))
        return String(letters).uppercased()
    }
}

/// "5h ▬▬▬▬▱▱ 62%": one window of an account row.
private struct MiniMeter: View {
    let label: String
    let limit: UsageLimit?
    @AppStorage(UsageDisplay.showsUsedKey) private var showsUsed = false

    var body: some View {
        let verdict = limit?.level ?? .comfortable
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 15, alignment: .leading)
            UsageBar(remaining: limit?.remaining, tint: UsageTint.color(verdict), height: 4)
                .frame(width: 64)
            // One line always: "100%" wrapped to "100 / %" in the 1.4.0 release build.
            Text(UsageFormat.compact(limit?.remaining, showsUsed: showsUsed))
                .font(.system(size: 10.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(UsageTint.text(verdict))
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 34, alignment: .trailing)
        }
    }
}

/// Provider picker across the top of the panel. Up to three providers get
/// a capsule segmented control with names; more get a strip of logo tiles
/// with the percentage under each.
public struct ProviderSwitcherView: View {
    public struct Tile: Identifiable {
        public let style: ProviderStyle
        public let remaining: Double?
        /// A status-page incident is open for this provider.
        public let hasIncident: Bool
        public var id: String { style.id }

        public init(style: ProviderStyle, remaining: Double?, hasIncident: Bool = false) {
            self.style = style
            self.remaining = remaining
            self.hasIncident = hasIncident
        }
    }

    let tiles: [Tile]
    let selected: String
    let onSelect: (String) -> Void
    @Namespace private var pill
    @AppStorage(UsageDisplay.showsUsedKey) private var showsUsed = false

    public init(tiles: [Tile], selected: String, onSelect: @escaping (String) -> Void) {
        self.tiles = tiles
        self.selected = selected
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(tiles) { tile in
                let isSelected = tile.id == selected
                Button {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) { onSelect(tile.id) }
                } label: {
                    label(tile, isSelected: isSelected)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, compact ? 5 : 6)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(tile.style.name)
            }
        }
        .padding(3)
        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.07)))
    }

    private var compact: Bool { tiles.count > 3 }

    @ViewBuilder
    private func label(_ tile: Tile, isSelected: Bool) -> some View {
        let percent = Text(tile.id == "overview" ? "All" : UsageFormat.compact(tile.remaining, showsUsed: showsUsed))
            .font(.system(size: compact ? 9.5 : 11, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        let logo = ProviderLogo(tile.style, size: compact ? 14 : 13)
            .foregroundStyle(isSelected ? tile.style.accent : Color.secondary)
            .overlay(alignment: .topTrailing) {
                if tile.hasIncident {
                    Circle().fill(Color.orange).frame(width: 5, height: 5).offset(x: 3, y: -2)
                }
            }
        if compact {
            VStack(spacing: 2) {
                logo
                percent
            }
        } else {
            HStack(spacing: 6) {
                logo
                Text(tile.style.name)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                percent
            }
        }
    }
}

/// A compact action tile (symbol over label), laid out in a row.
public struct PanelActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    public init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 13.5, weight: .medium))
                    .frame(height: 17)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering && isEnabled ? 0.09 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(PanelColors.hairline, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Small borderless icon button for the panel footer.
public struct PanelIconButton: View {
    let help: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    public init(_ help: String, symbol: String, action: @escaping () -> Void) {
        self.help = help
        self.symbol = symbol
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

public extension View {
    /// The panel's grouped-card background: a faint fill and a hairline.
    func panelCard(cornerRadius: CGFloat = 12) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(PanelColors.hairline, lineWidth: 0.5))
    }
}

/// Round initials badge for account rows in Settings (both providers).
public struct Initials: View {
    let text: String
    let tint: Color

    public init(text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(tint.gradient))
    }
}
