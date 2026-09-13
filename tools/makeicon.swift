// Renders the menu-bar glyph into a full macOS app icon (.icns).
// Run: swift tools/makeicon.swift  -> Resources/AppIcon.icns
import Cocoa

let symbolName = "character.book.closed"
let outDir = "Resources"
let iconset = "\(outDir)/AppIcon.iconset"

try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func tinted(_ img: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: img.size)
    out.lockFocus()
    let r = NSRect(origin: .zero, size: img.size)
    img.draw(in: r)
    color.set()
    r.fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

func render(_ px: Int) -> Data? {
    let size = CGFloat(px)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icons sit inset in their canvas with a squircle-ish corner.
    let inset = size * 0.06
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect,
                            xRadius: rect.width * 0.2237,
                            yRadius: rect.width * 0.2237)
    NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.44, blue: 0.72, alpha: 1),
               ending:   NSColor(calibratedRed: 0.20, green: 0.26, blue: 0.51, alpha: 1))?
        .draw(in: path, angle: -90)

    let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .medium)
    if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let white = tinted(sym, .white)
        let s = white.size
        white.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2,
                              width: s.width, height: s.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// name -> pixel size, per Apple's iconset layout
let want: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in want {
    guard let d = render(px) else { print("failed \(name)"); exit(1) }
    try! d.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
print("wrote \(want.count) pngs to \(iconset)")
