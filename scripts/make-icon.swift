#!/usr/bin/env swift
// Draws the Agent Profiles app icon and writes Resources/AppIcon.icns plus a
// preview at docs/icon.png. Usage: swift scripts/make-icon.swift [repo root]
//
// The mark: a dial with a fine scale and two gauge arcs chasing each other
// round it, Codex's blue over Claude's orange, each ending in a white knob.
// It reads as a swap (switching accounts) and as two meters (the usage each
// one has left).
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
    // Faint provider-colored light behind each arc.
    NSGradient(colors: [orange.withAlphaComponent(0.20), orange.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 512, y: 300), radius: 0, toCenter: NSPoint(x: 512, y: 300), radius: 420, options: [])
    NSGradient(colors: [blue.withAlphaComponent(0.16), blue.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 512, y: 724), radius: 0, toCenter: NSPoint(x: 512, y: 724), radius: 420, options: [])
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

/// Fine scale around the edge of the dial, every fifth tick stronger.
func drawTicks(center: CGPoint, radius: CGFloat) {
    for i in 0..<72 {
        let major = i % 6 == 0
        let angle = CGFloat(i) / 72 * 2 * .pi
        let inner = radius - (major ? 26 : 14)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
        path.line(to: NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
        path.lineWidth = major ? 5 : 3
        path.lineCapStyle = .round
        NSColor.white.withAlphaComponent(major ? 0.26 : 0.11).setStroke()
        path.stroke()
    }
}

/// A gauge arc (degrees, counterclockwise from `from` to `to`) with a
/// gradient along its sweep and a white knob at the leading end.
func drawArc(center: CGPoint, radius: CGFloat, width: CGFloat, from: CGFloat, to: CGFloat,
             color: NSColor, deep: NSColor) {
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: from, endAngle: to, clockwise: false)
    arc.lineWidth = width
    arc.lineCapStyle = .round
    withShadow(color.withAlphaComponent(0.60), blur: 60) {
        color.setStroke()
        arc.stroke()
    }
    // Fill the stroke's outline with a gradient running tail → head.
    let cg = NSGraphicsContext.current!.cgContext
    cg.saveGState()
    cg.addPath(arc.cgPath)
    cg.setLineWidth(width)
    cg.setLineCap(.round)
    cg.replacePathWithStrokedPath()
    cg.clip()
    let rad = { (deg: CGFloat) in deg * .pi / 180 }
    let tail = CGPoint(x: center.x + cos(rad(from)) * radius, y: center.y + sin(rad(from)) * radius)
    let head = CGPoint(x: center.x + cos(rad(to)) * radius, y: center.y + sin(rad(to)) * radius)
    NSGradient(starting: deep, ending: color)!.draw(from: tail, to: head, options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
    // Glass: a light band along the outer edge.
    let sheen = NSBezierPath()
    sheen.appendArc(withCenter: center, radius: radius + width * 0.22, startAngle: from, endAngle: to, clockwise: false)
    sheen.lineWidth = width * 0.22
    sheen.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.22).setStroke()
    sheen.stroke()
    cg.restoreGState()

    let d = width * 0.6
    let knob = CGRect(x: head.x - d / 2, y: head.y - d / 2, width: d, height: d)
    withShadow(NSColor.black.withAlphaComponent(0.35), blur: 16, offset: NSSize(width: 0, height: -5)) {
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
    }
    NSGradient(colors: [NSColor.white, NSColor(white: 0.88, alpha: 1)])!
        .draw(in: NSBezierPath(ovalIn: knob), angle: -90)
}

func drawIcon() {
    drawBackground()
    let center = CGPoint(x: canvas / 2, y: canvas / 2)
    drawTicks(center: center, radius: 392)
    // Two arcs chasing each other round the dial: a swap, and two meters.
    // Sized to fill the dial, so the middle reads as a hub, not a hole.
    let radius: CGFloat = 282, width: CGFloat = 158
    // Recessed face inside the arcs, lit by the arcs around it.
    let faceRadius = radius - width / 2 - 26
    let faceRect = CGRect(x: center.x - faceRadius, y: center.y - faceRadius,
                          width: faceRadius * 2, height: faceRadius * 2)
    let face = NSBezierPath(ovalIn: faceRect)
    NSGradient(colors: [inkDeep.withAlphaComponent(0.9), ink.withAlphaComponent(0.6)])!.draw(in: face, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    face.addClip()
    NSGradient(colors: [blue.withAlphaComponent(0.16), blue.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: center.x, y: faceRect.maxY), radius: 0,
              toCenter: NSPoint(x: center.x, y: faceRect.maxY), radius: faceRadius * 1.1, options: [])
    NSGradient(colors: [orange.withAlphaComponent(0.16), orange.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: center.x, y: faceRect.minY), radius: 0,
              toCenter: NSPoint(x: center.x, y: faceRect.minY), radius: faceRadius * 1.1, options: [])
    NSGraphicsContext.restoreGraphicsState()
    face.lineWidth = 3
    NSColor.white.withAlphaComponent(0.08).setStroke()
    face.stroke()
    drawArc(center: center, radius: radius, width: width, from: 30, to: 150, color: blue, deep: blueDeep)
    drawArc(center: center, radius: radius, width: width, from: 210, to: 330, color: orange, deep: orangeDeep)
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
