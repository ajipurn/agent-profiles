import SwiftUI

/// A thin capsule filled by the remaining share of a limit.
public struct UsageBar: View {
    let remaining: Double?
    let tint: Color
    var height: CGFloat
    /// Where an even burn would be now; drawn as a small tick.
    var evenTick: Double?

    public init(remaining: Double?, tint: Color, height: CGFloat = 6, evenTick: Double? = nil) {
        self.remaining = remaining
        self.tint = tint
        self.height = height
        self.evenTick = evenTick
    }

    public var body: some View {
        GeometryReader { proxy in
            let share = min(max((remaining ?? 0) / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: share > 0 ? max(height, proxy.size.width * share) : 0)
            }
            .frame(width: proxy.size.width, height: height)
            // An overlay, so the taller tick never stretches the bar itself.
            .overlay(alignment: .leading) {
                if let evenTick {
                    Capsule()
                        .fill(Color.primary.opacity(0.4))
                        .frame(width: 2, height: height + 4)
                        .offset(x: proxy.size.width * min(max(evenTick / 100, 0), 1) - 1)
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel(UsageFormat.percent(remaining) + " left")
    }
}

/// The selected provider: title, plan and account, any notice, then one
/// card of limit rows.
public struct UsageCardView: View {
    let model: UsageCardModel

    public init(model: UsageCardModel) {
        self.model = model
    }

    public var body: some View {
        // Countdowns and pace depend on the clock, not just the model.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 10) {
                header
                if let notice = model.notice {
                    NoticeView(text: notice, tone: model.noticeTone)
                }
                if !model.limits.isEmpty || model.placeholder != nil {
                    VStack(alignment: .leading, spacing: 16) {
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
                    }
                    .padding(14)
                    .panelCard()
                }
            }
            .opacity(model.isStale ? 0.7 : 1)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.provider.name)
                        .font(.system(size: 17, weight: .semibold))
                    if let badge = model.badge {
                        Text(badge)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                let line = [model.account, model.subtitle].compactMap { $0 }.joined(separator: " · ")
                if !line.isEmpty {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            ProviderLogo(model.provider, size: 20)
                .foregroundStyle(model.provider.accent)
        }
        .padding(.horizontal, 4)
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
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct LimitRow: View {
    let limit: UsageLimit
    let now: Date

    var body: some View {
        let pace = limit.pace(now: now)
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                paceNote(pace)
            }
            UsageBar(remaining: limit.remaining, tint: Self.color(pace.verdict),
                     evenTick: pace.verdict == .comfortable ? nil : pace.evenRemaining)
            HStack(alignment: .firstTextBaseline) {
                Text(limit.remaining.map { "\(UsageFormat.percent($0)) left" } ?? "No data yet")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                Spacer(minLength: 8)
                if let reset = UsageFormat.resetText(limit.resetsAt, now: now) {
                    Text(reset)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
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
                    .foregroundStyle(Color.yellow)
            }
        case .over:
            Label(UsageFormat.limitText((limit.remaining ?? 0).rounded() <= 0 ? nil : pace.runsOutAt ?? limit.resetsAt, now: now),
                  systemImage: "flame.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.red)
                .labelStyle(.titleAndIcon)
        }
    }

    /// One tint for every provider; only the verdict changes it.
    static func color(_ verdict: UsagePace.Verdict) -> Color {
        switch verdict {
        case .comfortable: ProviderStyle.usageTint
        case .tight: .yellow
        case .over: .red
        }
    }
}

/// One switchable account: name, a short session bar, percent. Lights up
/// on hover.
public struct AccountRowView: View {
    let account: UsageAccount
    let isEnabled: Bool
    let action: () -> Void
    @State private var hovering = false

    public init(account: UsageAccount, isEnabled: Bool, action: @escaping () -> Void) {
        self.account = account
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(account.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if account.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.yellow)
                }
                Spacer(minLength: 10)
                UsageBar(remaining: account.remaining, tint: ProviderStyle.usageTint, height: 5)
                    .frame(width: 60)
                Text(UsageFormat.percent(account.remaining))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle((account.remaining ?? 100) <= 10 ? Color.red : Color.secondary)
                    .frame(width: 34, alignment: .trailing)
                Image(systemName: "arrow.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .opacity(hovering && isEnabled ? 1 : 0)
                    .offset(x: hovering && isEnabled ? 0 : -4)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10)
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
    }
}

/// Capsule segmented control across the top of the panel; a white pill
/// marks the picked provider.
public struct ProviderSwitcherView: View {
    public struct Tile: Identifiable {
        public let style: ProviderStyle
        public let remaining: Double?
        public var id: String { style.name }

        public init(style: ProviderStyle, remaining: Double?) {
            self.style = style
            self.remaining = remaining
        }
    }

    let tiles: [Tile]
    let selected: String
    let onSelect: (String) -> Void

    public init(tiles: [Tile], selected: String, onSelect: @escaping (String) -> Void) {
        self.tiles = tiles
        self.selected = selected
        self.onSelect = onSelect
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(tiles) { tile in
                let isSelected = tile.id == selected
                Button { onSelect(tile.id) } label: {
                    HStack(spacing: 6) {
                        ProviderLogo(tile.style, size: 13)
                            .foregroundStyle(isSelected ? tile.style.accent : Color.secondary)
                        Text(tile.style.name)
                            .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        Text(UsageFormat.percent(tile.remaining))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

/// A compact action tile (symbol over label), laid out in a row.
public struct PanelActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    public init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .frame(height: 18)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : 0.045))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 28, height: 24)
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
    /// The panel's grouped-card background.
    func panelCard() -> some View {
        background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
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
