// Draws the ChemClip app icon (a clipboard holding a benzene ring) and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the package directory)
import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    // Work top-down like a design canvas.
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [CGFloat(hex >> 16 & 255) / 255, CGFloat(hex >> 8 & 255) / 255, CGFloat(hex & 255) / 255, a])!
    }

    // Background tile on the macOS icon grid (824 pt square, continuous-ish corners) with a soft drop shadow.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tile); ctx.setFillColor(color(0x0F4C75)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(tile); ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x2BB3A3), color(0x0E5A86)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 100), end: CGPoint(x: 824, y: 924), options: [])
    ctx.restoreGState()

    // Clipboard board.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: color(0x062B40, 0.45))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 262, y: 222, width: 500, height: 600), cornerWidth: 56, cornerHeight: 56, transform: nil))
    ctx.setFillColor(color(0xFBFDFD)); ctx.fillPath()
    ctx.restoreGState()
    // Clip at the top.
    ctx.addPath(CGPath(roundedRect: CGRect(x: 392, y: 182, width: 240, height: 92), cornerWidth: 30, cornerHeight: 30, transform: nil))
    ctx.setFillColor(color(0x23415A)); ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 472, y: 204, width: 80, height: 22), cornerWidth: 11, cornerHeight: 11, transform: nil))
    ctx.setFillColor(color(0xFBFDFD, 0.9)); ctx.fillPath()

    // Benzene ring (Kekulé): hexagon with three inner double bonds.
    let center = CGPoint(x: 512, y: 548), r: CGFloat = 158
    let corners = (0..<6).map { i -> CGPoint in
        let a = CGFloat.pi / 6 + CGFloat(i) * .pi / 3
        return CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a))
    }
    ctx.setStrokeColor(color(0x12707F)); ctx.setLineWidth(30); ctx.setLineJoin(.round); ctx.setLineCap(.round)
    ctx.addLines(between: corners + [corners[0]]); ctx.closePath(); ctx.strokePath()
    for i in stride(from: 0, to: 6, by: 2) {
        let a = corners[i], b = corners[(i + 1) % 6]
        func inset(_ p: CGPoint) -> CGPoint { CGPoint(x: center.x + (p.x - center.x) * 0.68, y: center.y + (p.y - center.y) * 0.68) }
        let p = inset(a), q = inset(b)
        let trim: CGFloat = 0.14
        ctx.move(to: CGPoint(x: p.x + (q.x - p.x) * trim, y: p.y + (q.y - p.y) * trim))
        ctx.addLine(to: CGPoint(x: q.x + (p.x - q.x) * trim, y: q.y + (p.y - q.y) * trim))
    }
    ctx.setLineWidth(26); ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ChemClip-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try drawIcon(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
if CommandLine.arguments.contains("--preview") {
    try drawIcon(size: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments.last!))
}
print("Wrote Resources/AppIcon.icns")
