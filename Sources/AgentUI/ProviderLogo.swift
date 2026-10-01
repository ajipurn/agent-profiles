import SwiftUI

/// A provider's brand mark, drawn from the SVG path data of
/// [Lobe Icons](https://github.com/lobehub/lobe-icons) (MIT, 24×24 viewBox).
/// Fills with the current foreground style, like an SF Symbol.
public struct ProviderLogo: View {
    let style: ProviderStyle
    let size: CGFloat

    public init(_ style: ProviderStyle, size: CGFloat = 14) {
        self.style = style
        self.size = size
    }

    public var body: some View {
        LogoShape(path: style.logoPath)
            .fill(style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
            .accessibilityLabel(style.name)
    }
}

private struct LogoShape: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        return path.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

extension ProviderStyle {
    var logoPath: Path {
        switch name {
        case Self.codex.name: LogoPaths.codex
        default: LogoPaths.claude
        }
    }
}

private enum LogoPaths {
    static let claude = SVGPath.parse("M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z")

    static let codex = SVGPath.parse("M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 1.695h4.848a.849.849 0 000-1.696h-4.848z")
}

/// Just enough of the SVG path grammar for the vendored logos:
/// M L H V C S A Z, absolute and relative, with compact number syntax.
enum SVGPath {
    static func parse(_ data: String) -> Path {
        var scanner = Tokens(Array(data.utf8))
        var path = Path()
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var command: UInt8 = 0

        while let next = scanner.command() ?? (command == 0 ? nil : implicit(after: command)) {
            command = next
            let relative = command >= UInt8(ascii: "a")
            let origin = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: origin.x + x, y: origin.y + y)
            }
            var control: CGPoint?
            switch command | 0x20 { // lowercase
            case UInt8(ascii: "m"):
                guard let p = point() else { return path }
                path.move(to: p)
                current = p; start = p
            case UInt8(ascii: "l"):
                guard let p = point() else { return path }
                path.addLine(to: p); current = p
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current.x = origin.x + x; path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current.y = origin.y + y; path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p; control = c2
            case UInt8(ascii: "s"):
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                guard let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p; control = c2
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let angle = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = point() else { return path }
                addArc(to: &path, from: current, to: p, rx: rx, ry: ry,
                       angle: angle * .pi / 180, large: large, sweep: sweep)
                current = p
            case UInt8(ascii: "z"):
                path.closeSubpath(); current = start
            default:
                return path
            }
            lastControl = control
        }
        return path
    }

    /// Numbers after a command repeat it (a moveto repeats as a lineto).
    private static func implicit(after command: UInt8) -> UInt8? {
        switch command {
        case UInt8(ascii: "z"), UInt8(ascii: "Z"): nil
        case UInt8(ascii: "M"): UInt8(ascii: "L")
        case UInt8(ascii: "m"): UInt8(ascii: "l")
        default: command
        }
    }

    /// Endpoint-parameterized elliptical arc → cubic Béziers (SVG 1.1 F.6).
    private static func addArc(to path: inout Path, from p0: CGPoint, to p1: CGPoint,
                               rx: Double, ry: Double, angle: Double, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let cosA = cos(angle), sinA = sin(angle)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosA * dx + sinA * dy, y1 = -sinA * dx + cosA * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = (max(num, 0) / den).squareRoot()
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let cx = cosA * cx1 - sinA * cy1 + (p0.x + p1.x) / 2
        let cy = sinA * cx1 + cosA * cy1 + (p0.y + p1.y) / 2

        func vectorAngle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let theta1 = vectorAngle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = vectorAngle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = Int((abs(delta) / (.pi / 2)).rounded(.up))
        let step = delta / Double(segments)
        let k = 4 / 3 * tan(step / 4)
        func onEllipse(_ t: Double) -> (CGPoint, CGPoint) { // point, derivative
            let x = rx * cos(t), y = ry * sin(t)
            let dx = -rx * sin(t), dy = ry * cos(t)
            return (CGPoint(x: cx + cosA * x - sinA * y, y: cy + sinA * x + cosA * y),
                    CGPoint(x: cosA * dx - sinA * dy, y: sinA * dx + cosA * dy))
        }
        var t = theta1
        for i in 0..<segments {
            let (a, da) = onEllipse(t)
            let (b, db) = onEllipse(t + step)
            path.addCurve(to: i == segments - 1 ? p1 : b,
                          control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                          control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
            t += step
        }
    }

    private struct Tokens {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        private mutating func skipSeparators() {
            while index < bytes.count, bytes[index] == UInt8(ascii: " ") || bytes[index] == UInt8(ascii: ",")
                    || bytes[index] == UInt8(ascii: "\n") || bytes[index] == UInt8(ascii: "\t") {
                index += 1
            }
        }

        mutating func command() -> UInt8? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index] | 0x20
            guard byte >= UInt8(ascii: "a"), byte <= UInt8(ascii: "z"), byte != UInt8(ascii: "e") else { return nil }
            index += 1
            return bytes[index - 1]
        }

        /// Arc flags are a single digit and may run into the next number.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "0") || bytes[index] == UInt8(ascii: "1")
            else { return nil }
            index += 1
            return bytes[index - 1] == UInt8(ascii: "1")
        }

        mutating func number() -> Double? {
            skipSeparators()
            let begin = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            var sawDot = false, sawDigit = false
            while index < bytes.count {
                let b = bytes[index]
                if b >= UInt8(ascii: "0"), b <= UInt8(ascii: "9") { sawDigit = true }
                else if b == UInt8(ascii: "."), !sawDot { sawDot = true }
                else if (b | 0x20) == UInt8(ascii: "e"), sawDigit {
                    index += 1
                    if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
                    continue
                } else { break }
                index += 1
            }
            guard sawDigit else { index = begin; return nil }
            return Double(String(decoding: bytes[begin..<index], as: UTF8.self))
        }
    }
}
