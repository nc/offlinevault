#!/usr/bin/env swift
// Renders the OfflineVault app icon (a vault door with a shield cut-out on a deep green ground) at every size
// macOS needs and writes an .icns. Run: swift scripts/icon/make_icon.swift OfflineVault/Resources/AppIcon.icns
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns")
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: tmp); try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size
    let inset = s * 0.08
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.19, yRadius: s * 0.19)
    NSGradient(colors: [NSColor(calibratedRed: 0.11, green: 0.34, blue: 0.26, alpha: 1), NSColor(calibratedRed: 0.05, green: 0.18, blue: 0.14, alpha: 1)])!.draw(in: bg, angle: -70)
    // subtle vignette ring
    NSColor.black.withAlphaComponent(0.18).setStroke(); bg.lineWidth = s * 0.01; bg.stroke()
    // vault door: circle with ring and spoke handle
    let c = NSPoint(x: s * 0.5, y: s * 0.5)
    let r = s * 0.30
    let door = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    NSGradient(colors: [NSColor(calibratedWhite: 0.93, alpha: 1), NSColor(calibratedWhite: 0.70, alpha: 1)])!.draw(in: door, angle: -90)
    NSColor(calibratedWhite: 0.25, alpha: 0.35).setStroke(); door.lineWidth = s * 0.012; door.stroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r * 0.78, y: c.y - r * 0.78, width: 2 * r * 0.78, height: 2 * r * 0.78))
    NSColor(calibratedRed: 0.09, green: 0.28, blue: 0.21, alpha: 1).setStroke(); ring.lineWidth = s * 0.045; ring.stroke()
    // spokes
    NSColor(calibratedRed: 0.09, green: 0.28, blue: 0.21, alpha: 1).setStroke()
    for i in 0..<4 {
        let a = CGFloat(i) * .pi / 4
        let p = NSBezierPath(); p.lineWidth = s * 0.045; p.lineCapStyle = .round
        p.move(to: NSPoint(x: c.x + cos(a) * r * 0.72, y: c.y + sin(a) * r * 0.72)); p.line(to: NSPoint(x: c.x - cos(a) * r * 0.72, y: c.y - sin(a) * r * 0.72)); p.stroke()
    }
    // hub
    let hub = NSBezierPath(ovalIn: NSRect(x: c.x - r * 0.22, y: c.y - r * 0.22, width: r * 0.44, height: r * 0.44))
    NSColor(calibratedRed: 0.95, green: 0.68, blue: 0.18, alpha: 1).setFill(); hub.fill()
    NSColor(calibratedWhite: 0.2, alpha: 0.4).setStroke(); hub.lineWidth = s * 0.008; hub.stroke()
    // small signal bars bottom-right (offline, still on)
    let bars = NSBezierPath()
    for i in 0..<3 { let h = s * (0.06 + CGFloat(i) * 0.035); bars.appendRect(NSRect(x: s * 0.70 + CGFloat(i) * s * 0.055, y: s * 0.18, width: s * 0.035, height: h)) }
    NSColor(calibratedRed: 0.95, green: 0.68, blue: 0.18, alpha: 0.95).setFill(); bars.fill()
    img.unlockFocus()
    return img
}

for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let img = draw(size: CGFloat(px))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: tmp.appendingPathComponent(name + ".png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); p.arguments = ["-c", "icns", tmp.path, "-o", out.path]; try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
