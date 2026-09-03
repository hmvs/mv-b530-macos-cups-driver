// Draws the app icon and writes packaging/AppIcon.icns.
//
// PAPPL's menu bar item is a copy of the application icon, so a bundle
// without one shows the empty placeholder square. Generated rather than
// committed as a binary: the shapes stay reviewable, and it costs one command
// to change them.
//
//     swift scripts/make-icon.swift
import AppKit

/// A charcoal tile with a page on it - legible against both a light and a
/// dark menu bar, which a flat glyph on transparency is not.
func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels,
                               pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    func unit(_ value: CGFloat) -> CGFloat { value * size }

    let tile = NSBezierPath(roundedRect: NSRect(x: unit(0.06), y: unit(0.06),
                                                width: unit(0.88), height: unit(0.88)),
                            xRadius: unit(0.22), yRadius: unit(0.22))
    NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.17, alpha: 1).setFill()
    tile.fill()

    // The page, sitting slightly high so the feed slot below it reads as one.
    let page = NSBezierPath(roundedRect: NSRect(x: unit(0.28), y: unit(0.30),
                                                width: unit(0.44), height: unit(0.50)),
                            xRadius: unit(0.03), yRadius: unit(0.03))
    NSColor.white.setFill()
    page.fill()

    // Lines of print, shortest last, so it reads as text rather than stripes.
    NSColor(calibratedWhite: 0.62, alpha: 1).setFill()
    for (index, width) in [0.30, 0.30, 0.22].enumerated() {
        let y = unit(0.66) - CGFloat(index) * unit(0.09)
        NSBezierPath(rect: NSRect(x: unit(0.35), y: y,
                                  width: unit(width), height: unit(0.035))).fill()
    }

    // The heated line at the head, the one thing this printer actually does.
    NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.15, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: unit(0.24), y: unit(0.20),
                                     width: unit(0.52), height: unit(0.055)),
                 xRadius: unit(0.028), yRadius: unit(0.028)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.first.map {
    URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path
} ?? ".")
let iconset = root.appendingPathComponent("packaging/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = drawIcon(size: CGFloat(base * scale))
        guard let data = rep.representation(using: .png, properties: [:]) else { continue }
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", root.appendingPathComponent("packaging/AppIcon.icns").path]
try convert.run()
convert.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(convert.terminationStatus == 0 ? "wrote packaging/AppIcon.icns"
                                     : "iconutil failed")
