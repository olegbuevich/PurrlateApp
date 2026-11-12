// Renders Purrlate/AppIcon.icns (a cat-eared speech bubble).
// Run from the project root: swift tools/make-icon.swift
import AppKit

let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}
func triangle(_ a: NSPoint, _ b: NSPoint, _ c: NSPoint) -> NSBezierPath {
    let p = NSBezierPath(); p.move(to: a); p.line(to: b); p.line(to: c); p.close(); return p
}

// Background: macOS-style rounded square with a soft shadow.
let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = .black.withAlphaComponent(0.3)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
color(0x6A4BE0).setFill()
body.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: color(0x9B7BF7), ending: color(0x5636CF))!.draw(in: body, angle: -90)

// Speech bubble with cat ears and a tail (one shadow for all parts).
let parts = [
    NSBezierPath(roundedRect: NSRect(x: 240, y: 300, width: 544, height: 390), xRadius: 130, yRadius: 130),
    triangle(NSPoint(x: 265, y: 590), NSPoint(x: 310, y: 830), NSPoint(x: 490, y: 690)),
    triangle(NSPoint(x: 759, y: 590), NSPoint(x: 714, y: 830), NSPoint(x: 534, y: 690)),
    triangle(NSPoint(x: 330, y: 330), NSPoint(x: 280, y: 205), NSPoint(x: 450, y: 305)),
]
let cg = NSGraphicsContext.current!.cgContext
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor.black.withAlphaComponent(0.2).cgColor)
cg.beginTransparencyLayer(auxiliaryInfo: nil)
NSColor.white.setFill()
parts.forEach { $0.fill() }
cg.endTransparencyLayer()
cg.restoreGState()

// Inner ears.
color(0xF3B4D6).setFill()
triangle(NSPoint(x: 308, y: 650), NSPoint(x: 330, y: 770), NSPoint(x: 430, y: 690)).fill()
triangle(NSPoint(x: 716, y: 650), NSPoint(x: 694, y: 770), NSPoint(x: 594, y: 690)).fill()

// "Aя" — Latin and Cyrillic letters.
let font = NSFont.systemFont(ofSize: 240, weight: .heavy)
let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 240) } ?? font
let text = NSAttributedString(string: "Aя", attributes: [.font: rounded, .foregroundColor: color(0x5A3AD3)])
let t = text.size()
text.draw(at: NSPoint(x: 512 - t.width / 2, y: 488 - t.height / 2))

NSGraphicsContext.current = nil

// Write an .iconset and convert it with iconutil.
let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = NSImage(size: NSSize(width: size, height: size))
master.addRepresentation(rep)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        master.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.current = nil
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try out.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Purrlate/AppIcon.icns"]
try task.run()
task.waitUntilExit()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "tools/AppIcon-preview.png"))
print(task.terminationStatus == 0 ? "Wrote Purrlate/AppIcon.icns" : "iconutil failed")
