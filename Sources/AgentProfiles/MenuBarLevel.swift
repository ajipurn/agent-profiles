import AppKit

// MARK: - Menu bar images

/// Menu bar readout, drawn with AppKit into a single full-color NSImage
/// (ClaudeBar-style): "◐ 51%" — the dot and the remaining share of the
/// active account's 5-hour window, both tinted green/yellow/red like the
/// window's meters. One image because macOS flattens any other status-item
/// content to a monochrome template, and sibling views next to an NSImage
/// proved unreliable.
enum MenuBarLevel {
    @MainActor private static var cache: [String: NSImage] = [:]

    /// `remaining == nil` = no cached usage for this account yet: gray "--"
    /// and an empty ring instead of the colored gauge. `stale` keeps the value
    /// but drops the traffic-light color — old numbers must not read as live.
    @MainActor static func composite(remaining: Int?, suffix: String? = nil, stale: Bool = false) -> NSImage {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = "text-\(remaining.map(String.init) ?? "nil")-\(suffix ?? "")-\(stale)-\(dark)"
        if let hit = cache[key] { return hit }

        let color: NSColor = {
            guard let remaining, !stale else { return .lightGray }
            return remaining > 40 ? .systemGreen
                : remaining > 10 ? .systemYellow : .systemRed
        }()
        // Same face as ClaudeBar's readout.
        let font = NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.systemFontSize(for: .small), weight: .medium)
        let value = remaining.map { "\($0)%" } ?? "--"
        let text = suffix.map { "\(value) · \($0)" } ?? value
        let attr = NSAttributedString(string: text,
                                      attributes: [.font: font, .foregroundColor: color])

        let textSize = attr.size()
        let padding: CGFloat = 6
        let dotSide: CGFloat = 10
        let gap: CGFloat = 4
        let size = NSSize(width: padding + dotSide + gap + ceil(textSize.width) + padding,
                          height: NSStatusBar.system.thickness)

        let image = NSImage(size: size, flipped: false) { _ in
            // Solid black pill behind the readout — the colored text alone
            // washes out on bright wallpapers under the translucent menu bar.
            let pillHeight: CGFloat = 20
            let pill = NSRect(x: 0, y: (size.height - pillHeight) / 2,
                              width: size.width, height: pillHeight)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: pill, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()

            // The dot is a live gauge, not a glyph: a ring whose pie fill is
            // the remaining share — full disc at 100%, a sliver near empty.
            let dotRect = NSRect(x: padding, y: (size.height - dotSide) / 2,
                                 width: dotSide, height: dotSide)
            color.set()
            if let remaining {
                if remaining >= 100 {
                    NSBezierPath(ovalIn: dotRect).fill()
                } else if remaining > 0 {
                    let wedge = NSBezierPath()
                    let center = NSPoint(x: dotRect.midX, y: dotRect.midY)
                    wedge.move(to: center)
                    wedge.appendArc(withCenter: center, radius: dotSide / 2,
                                    startAngle: 90,
                                    endAngle: 90 - 360 * CGFloat(remaining) / 100,
                                    clockwise: true)
                    wedge.close()
                    wedge.fill()
                }
            }
            let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()

            attr.draw(at: NSPoint(x: padding + dotSide + gap,
                                  y: (size.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }
}
