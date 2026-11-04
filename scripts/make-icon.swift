#!/usr/bin/env swift
// Draws the Agent Profiles app icon and writes Resources/AppIcon.icns plus a
// preview at docs/icon.png. Usage: swift scripts/make-icon.swift [repo root]
//
// The mark is the menu bar icon, enlarged: two meters, a thick session bar
// over a thinner weekly bar, each partly filled. Claude's orange fills the
// top one and Codex's blue the bottom one.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)

let canvas: CGFloat = 1024
// macOS icon grid: an 824 pt body centered on the 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

let orange = NSColor(srgbRed: 0.95, green: 0.55, blue: 0.38, alpha: 1)
let orangeDeep = NSColor(srgbRed: 0.80, green: 0.35, blue: 0.23, alpha: 1)
let blue = NSColor(srgbRed: 0.45, green: 0.58, blue: 1.0, alpha: 1)
let blueDeep = NSColor(srgbRed: 0.18, green: 0.25, blue: 0.97, alpha: 1)
let ink = NSColor(srgbRed: 0.14, green: 0.15, blue: 0.20, alpha: 1)
let inkDeep = NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1)

/// Superellipse close to Apple's continuous-corner icon body.
func squircle(_ rect: CGRect, exponent n: CGFloat = 5.2) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    for step in 0...1440 {
        let t = CGFloat(step) / 1440 * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = NSPoint(x: rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                            y: rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        step == 0 ? path.move(to: point) : path.line(to: point)
    }
    path.close()
    return path
}

func withShadow(_ color: NSColor, blur: CGFloat, offset: NSSize = .zero, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = offset
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func drawBackground() {
    let shape = squircle(body)
    withShadow(NSColor.black.withAlphaComponent(0.32), blur: 30, offset: NSSize(width: 0, height: -12)) {
        ink.setFill()
        shape.fill()
    }
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: ink, ending: inkDeep)!.draw(in: body, angle: -90)
    // Faint provider-colored light behind each meter.
    NSGradient(colors: [orange.withAlphaComponent(0.20), orange.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 400, y: 640), radius: 0, toCenter: NSPoint(x: 400, y: 640), radius: 440, options: [])
    NSGradient(colors: [blue.withAlphaComponent(0.18), blue.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 340, y: 330), radius: 0, toCenter: NSPoint(x: 340, y: 330), radius: 400, options: [])
    // Top sheen.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.09), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    // Hairline edge catches the light on dark menus and docks.
    let edge = squircle(body.insetBy(dx: 1.5, dy: 1.5))
    edge.lineWidth = 3
    NSColor.white.withAlphaComponent(0.09).setStroke()
    edge.stroke()
}

/// Layout of the menu bar icon (UsageIcon.swift, 18 pt canvas): a 15 x 6
/// session meter 3 pt above a 15 x 4 weekly meter. Scaled up here, a little
/// slimmer, since at this size the menu bar's proportions read as switches.
let unit: CGFloat = 38
let meterWidth = 16.4 * unit
let sessionHeight = 5.2 * unit, weeklyHeight = 3.5 * unit, meterGap = 2.6 * unit
let meterX = (canvas - meterWidth) / 2
let weeklyY = (canvas - (sessionHeight + meterGap + weeklyHeight)) / 2
let sessionY = weeklyY + weeklyHeight + meterGap

/// A capsule track with a recessed look and a glowing fill of `share`.
func drawMeter(_ rect: CGRect, share: CGFloat, color: NSColor, deep: NSColor) {
    let radius = rect.height / 2
    let track = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    // Recessed track: darker than the body, lit along its lower lip.
    NSGradient(colors: [inkDeep.withAlphaComponent(0.95), ink.withAlphaComponent(0.85)])!.draw(in: track, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    track.addClip()
    withShadow(NSColor.black.withAlphaComponent(0.55), blur: 18, offset: NSSize(width: 0, height: -6)) {
        let rim = NSBezierPath(roundedRect: rect.insetBy(dx: -20, dy: -20), xRadius: radius + 20, yRadius: radius + 20)
        rim.append(track.reversed)
        NSColor.black.setFill()
        rim.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    track.lineWidth = 3
    NSColor.white.withAlphaComponent(0.10).setStroke()
    track.stroke()

    // The fill: an inset capsule, so it reads as liquid in a tube.
    let inset = rect.height * 0.1
    let inner = rect.insetBy(dx: inset, dy: inset)
    let fillRect = CGRect(x: inner.minX, y: inner.minY,
                          width: max(inner.height, inner.width * share), height: inner.height)
    let fillRadius = fillRect.height / 2
    let fill = NSBezierPath(roundedRect: fillRect, xRadius: fillRadius, yRadius: fillRadius)
    withShadow(color.withAlphaComponent(0.65), blur: 56) {
        color.setFill()
        fill.fill()
    }
    NSGradient(starting: deep, ending: color)!.draw(in: fill, angle: 0)
    // Glass: light fading down from the top edge.
    NSGraphicsContext.saveGraphicsState()
    fill.addClip()
    NSGradient(colorsAndLocations: (NSColor.white.withAlphaComponent(0.34), 0),
               (NSColor.white.withAlphaComponent(0.08), 0.45),
               (NSColor.white.withAlphaComponent(0), 1))!
        .draw(in: fillRect, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
}

func drawIcon() {
    drawBackground()
    drawMeter(CGRect(x: meterX, y: sessionY, width: meterWidth, height: sessionHeight),
              share: 0.74, color: orange, deep: orangeDeep)
    drawMeter(CGRect(x: meterX, y: weeklyY, width: meterWidth, height: weeklyHeight),
              share: 0.46, color: blue, deep: blueDeep)
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AgentProfiles-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

let docs = root.appendingPathComponent("docs")
try fm.createDirectory(at: docs, withIntermediateDirectories: true)
try png(pixels: 512).write(to: docs.appendingPathComponent("icon.png"))
print("wrote \(icns.path) and docs/icon.png")
