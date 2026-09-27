import SwiftUI

// MARK: - Design tokens (single source of truth for panel polish)

enum PanelDS {
    static let panelWidth: CGFloat = 440
    static let contentPadding: CGFloat = 16
    static let maxPanelHeight: CGFloat = 640
    static let cardRadius: CGFloat = 16
    static let rowRadius: CGFloat = 12
    static let controlRadius: CGFloat = 10

    static let microLabel = Font.system(size: 10, weight: .semibold)
    static let caption = Font.system(size: 11)
    static let body = Font.system(size: 12)
    static let title = Font.system(size: 13, weight: .semibold)
    static let headline = Font.system(size: 13.5, weight: .semibold)
}

struct PressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration, pressedScale: pressedScale)
    }

    private struct PressableBody: View {
        let configuration: ButtonStyle.Configuration
        var pressedScale: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : pressedScale)
                .opacity(configuration.isPressed ? 0.86 : 1)
                .animation(
                    reduceMotion ? nil : .easeOut(duration: 0.12),
                    value: configuration.isPressed
                )
        }
    }
}

/// Subtle icon-only button used for search accessories, favorites, sort, row menus.
struct PanelIconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var active: Bool = false
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .frame(width: size, height: size)
            .foregroundStyle(active ? tint : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? tint.opacity(0.13) : Color.primary.opacity(configuration.isPressed ? 0.09 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(active ? tint.opacity(0.22) : Color.primary.opacity(0.06), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Card background shared by hero + banners.
struct PanelCard: ViewModifier {
    var tint: Color = .accentColor
    var tintStrength: Double = 0.07
    var strokeStrength: Double = 0.13
    var radius: CGFloat = PanelDS.cardRadius

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(tintStrength + 0.035), tint.opacity(tintStrength - 0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(tint.opacity(strokeStrength), lineWidth: 1)
            )
    }
}

extension View {
    func panelCard(tint: Color = .accentColor, tintStrength: Double = 0.07, strokeStrength: Double = 0.13, radius: CGFloat = PanelDS.cardRadius) -> some View {
        modifier(PanelCard(tint: tint, tintStrength: tintStrength, strokeStrength: strokeStrength, radius: radius))
    }
}

/// Deterministic, pleasant avatar gradients per account (works in light + dark).
enum AvatarPalette {
    static func gradient(for seed: String) -> LinearGradient {
        let hash = abs(seed.hashValue)
        let palettes: [[Color]] = [
            [.blue, .teal],
            [.indigo, .blue],
            [.purple, .pink],
            [.teal, .green],
            [.orange, .pink],
            [.cyan, .indigo],
        ]
        let pair = palettes[hash % palettes.count]
        return LinearGradient(colors: pair, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Shared gradient avatar: legible on light/dark, subtle ring, soft shadow for hero.
struct AccountAvatar: View {
    var seed: String
    var initials: String
    var size: CGFloat = 34
    var emphasized: Bool = false
    var body: some View {
        ZStack {
            Circle()
                .fill(AvatarPalette.gradient(for: seed))
                .opacity(emphasized ? 1 : 0.86)
            Text(initials)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(.white.opacity(emphasized ? 0.5 : 0.28), lineWidth: 1))
        .accessibilityHidden(true)
    }
}
