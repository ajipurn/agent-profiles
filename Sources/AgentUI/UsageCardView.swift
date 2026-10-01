import SwiftUI

/// Whether the menu row hosting a view is highlighted (mouse or keyboard).
@MainActor
public final class MenuHighlight: ObservableObject {
    @Published public var isHighlighted = false
    public init() {}
}

/// A thin capsule filled by the remaining share of a limit.
public struct UsageBar: View {
    let remaining: Double?
    let tint: Color
    var height: CGFloat = 6
    var onHighlight = false

    public init(remaining: Double?, tint: Color, height: CGFloat = 6, onHighlight: Bool = false) {
        self.remaining = remaining
        self.tint = tint
        self.height = height
        self.onHighlight = onHighlight
    }

    public var body: some View {
        GeometryReader { proxy in
            let share = min(max((remaining ?? 0) / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(onHighlight ? Color.white.opacity(0.3) : Color.primary.opacity(0.1))
                if share > 0 {
                    Capsule()
                        .fill(onHighlight ? Color.white : tint)
                        .frame(width: max(height, proxy.size.width * share))
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel(UsageFormat.percent(remaining) + " left")
    }
}

/// The provider card at the top of the menu: title and account, freshness,
/// then one labeled bar per limit window.
public struct UsageCardView: View {
    let model: UsageCardModel

    public init(model: UsageCardModel) {
        self.model = model
    }

    public var body: some View {
        // Countdowns depend on the clock, not just the model.
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider().padding(.vertical, 10)
                if let notice = model.notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(noticeColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, model.limits.isEmpty && model.placeholder == nil ? 0 : 10)
                }
                if model.limits.isEmpty {
                    if let placeholder = model.placeholder {
                        Text(placeholder)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(model.limits) { limit in
                            LimitRow(limit: limit, tint: ProviderStyle.usageTint, now: context.date)
                        }
                    }
                }
            }
            .opacity(model.isStale ? 0.7 : 1)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.provider.name)
                    .font(.headline)
                Spacer(minLength: 8)
                if let account = model.account {
                    Text(account)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let subtitle = model.subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let badge = model.badge {
                    Text(badge)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var noticeColor: Color {
        switch model.noticeTone {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct LimitRow: View {
    let limit: UsageLimit
    let tint: Color
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(limit.title)
                .font(.body)
                .fontWeight(.medium)
            UsageBar(remaining: limit.remaining, tint: tint)
            HStack(alignment: .firstTextBaseline) {
                Text(limit.remaining.map { "\(UsageFormat.percent($0)) left" } ?? "No data yet")
                    .font(.footnote)
                    .foregroundStyle((limit.remaining ?? 100) <= 10 ? Color.red : Color.primary)
                Spacer(minLength: 8)
                if let reset = UsageFormat.resetText(limit.resetsAt, now: now) {
                    Text(reset)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// One switchable account in the menu: name, a short session bar, percent.
public struct AccountRowView: View {
    let account: UsageAccount
    let tint: Color
    let isEnabled: Bool
    @ObservedObject var highlight: MenuHighlight

    public init(account: UsageAccount, tint: Color, isEnabled: Bool, highlight: MenuHighlight) {
        self.account = account
        self.tint = tint
        self.isEnabled = isEnabled
        self.highlight = highlight
    }

    public var body: some View {
        let lit = highlight.isHighlighted && isEnabled
        HStack(spacing: 6) {
            Text(account.title)
                .lineLimit(1)
                .truncationMode(.middle)
            if account.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(lit ? Color.white : Color.yellow)
            }
            Spacer(minLength: 10)
            UsageBar(remaining: account.remaining, tint: tint, height: 5, onHighlight: lit)
                .frame(width: 64)
            Text(UsageFormat.percent(account.remaining))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(lit ? Color.white : ((account.remaining ?? 100) <= 10 ? Color.red : Color.secondary))
                .frame(width: 36, alignment: .trailing)
        }
        .foregroundStyle(lit ? Color.white : Color.primary)
        .opacity(isEnabled ? 1 : 0.45)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

/// Provider tabs across the top of the menu, each with a small session bar.
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

    public init(tiles: [Tile], selected: String) {
        self.tiles = tiles
        self.selected = selected
    }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(tiles) { tile in
                let isSelected = tile.id == selected
                VStack(spacing: 3) {
                    HStack(spacing: 5) {
                        ProviderLogo(tile.style, size: 13)
                        Text(tile.style.name)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    }
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    UsageBar(remaining: tile.remaining, tint: ProviderStyle.usageTint, height: 3, onHighlight: isSelected)
                        .frame(width: 56)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
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
