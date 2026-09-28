#!/usr/bin/env swift
// Draws the Agent Profiles app icon and writes Resources/AppIcon.icns plus a
// preview at docs/icon.png. Usage: swift scripts/make-icon.swift [repo root]
//
// The mark: two pills offset like ⇄, Claude's orange over Codex's teal, each
// with its knob at the far end. It reads as a swap (switching accounts) and
// as a pair of switches/meters (the usage each one has left).
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)

let canvas: CGFloat = 1024
// macOS icon grid: an 824 pt body centered on the 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

let orange = NSColor(srgbRed: 0.95, green: 0.55, blue: 0.38, alpha: 1)
let orangeDeep = NSColor(srgbRed: 0.80, green: 0.35, blue: 0.23, alpha: 1)
let teal = NSColor(srgbRed: 0.24, green: 0.84, blue: 0.72, alpha: 1)
let tealDeep = NSColor(srgbRed: 0.06, green: 0.54, blue: 0.50, alpha: 1)
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

func pill(_ rect: CGRect) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
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
    // Faint provider-colored light behind each pill.
    NSGradient(colors: [orange.withAlphaComponent(0.20), orange.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 400, y: 640), radius: 0, toCenter: NSPoint(x: 400, y: 640), radius: 420, options: [])
    NSGradient(colors: [teal.withAlphaComponent(0.16), teal.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 624, y: 384), radius: 0, toCenter: NSPoint(x: 624, y: 384), radius: 420, options: [])
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

/// A glassy pill with its knob at one end.
func drawPill(_ rect: CGRect, knobAtRight: Bool, color: NSColor, deep: NSColor) {
    let shape = pill(rect)
    withShadow(color.withAlphaComponent(0.55), blur: 56) {
        color.setFill()
        shape.fill()
    }
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: color, ending: deep)!.draw(in: rect, angle: -90)
    // Glass highlight on the upper half.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.30), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: rect.minX, y: rect.midY - 6, width: rect.width, height: rect.height / 2 + 6), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    // Inner rim.
    let rim = pill(rect.insetBy(dx: 1.5, dy: 1.5))
    rim.lineWidth = 3
    NSColor.white.withAlphaComponent(0.22).setStroke()
    rim.stroke()

    let inset: CGFloat = 20
    let d = rect.height - inset * 2
    let knob = CGRect(x: knobAtRight ? rect.maxX - inset - d : rect.minX + inset,
                      y: rect.minY + inset, width: d, height: d)
    withShadow(NSColor.black.withAlphaComponent(0.30), blur: 18, offset: NSSize(width: 0, height: -6)) {
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
    }
    NSGradient(colors: [NSColor.white, NSColor(white: 0.90, alpha: 1)])!
        .draw(in: NSBezierPath(ovalIn: knob), angle: -90)
}

func drawIcon() {
    drawBackground()
    let height: CGFloat = 180, width: CGFloat = 548, offset: CGFloat = 92
    // Two pills, offset by `offset`, centered as a pair on the canvas.
    let left = (canvas - width - offset) / 2
    drawPill(CGRect(x: left, y: 536, width: width, height: height),
             knobAtRight: true, color: orange, deep: orangeDeep)
    drawPill(CGRect(x: left + offset, y: 308, width: width, height: height),
             knobAtRight: false, color: teal, deep: tealDeep)
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
