import AppKit

/// The menu bar icon: an 18×18 pt template image with two meters, session on
/// top and weekly below, each filled by the remaining share. Template images
/// follow the menu bar's own color; `dimmed` marks old or failed numbers.
@MainActor
public enum UsageIcon {
    private static var cache: [String: NSImage] = [:]

    public static func image(session: Double?, weekly: Double?, dimmed: Bool) -> NSImage {
        let key = "\(bucket(session))-\(bucket(weekly))-\(dimmed)"
        if let hit = cache[key] { return hit }

        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let ink = NSColor.black
            let trackAlpha: CGFloat = dimmed ? 0.18 : 0.28
            let strokeAlpha: CGFloat = dimmed ? 0.28 : 0.44
            let fillAlpha: CGFloat = dimmed ? 0.55 : 1

            func meter(_ rect: NSRect, _ remaining: Double?) {
                let radius = rect.height / 2
                let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
                ink.withAlphaComponent(trackAlpha).setFill()
                track.fill()
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                           xRadius: radius - 0.5, yRadius: radius - 0.5)
                outline.lineWidth = 1
                ink.withAlphaComponent(strokeAlpha).setStroke()
                outline.stroke()
                guard let remaining, remaining > 0 else { return }
                NSGraphicsContext.saveGraphicsState()
                track.addClip()
                ink.withAlphaComponent(fillAlpha).setFill()
                let width = (rect.width * min(remaining, 100) / 100).rounded()
                NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: max(1, width), height: rect.height)).fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            meter(NSRect(x: 1.5, y: 9.5, width: 15, height: 6), session)
            meter(NSRect(x: 1.5, y: 2.5, width: 15, height: 4), weekly)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Usage"
        cache[key] = image
        return image
    }

    /// Whole percents are plenty for an 15 pt bar and keep the cache small.
    private static func bucket(_ value: Double?) -> String {
        value.map { String(Int($0.rounded())) } ?? "nil"
    }
}
