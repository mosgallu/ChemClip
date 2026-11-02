// Draws the disk image window background: ChemClip on the left, a reaction arrow, Applications on the right.
// Usage: swift scripts/make-dmg-background.swift OUTPUT.tiff [--preview out.png]
// The TIFF holds 1x and 2x images; package.sh lays out the icons at the positions below.
import AppKit

let width: CGFloat = 640, height: CGFloat = 400
/// Icon centers in Finder window coordinates (origin top-left); package.sh uses the same values.
let appCenter = CGPoint(x: 160, y: 190), applicationsCenter = CGPoint(x: 480, y: 190)

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let ctx = context.cgContext
    // Work top-down like the Finder window.
    ctx.translateBy(x: 0, y: height); ctx.scaleBy(x: 1, y: -1)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [CGFloat(hex >> 16 & 255) / 255, CGFloat(hex >> 8 & 255) / 255, CGFloat(hex & 255) / 255, a])!
    }
    func nsColor(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor { NSColor(cgColor: color(hex, a))! }

    // Light wash in the icon's teal, so Finder's dark icon labels stay readable.
    let wash = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xE6F4F2)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(wash, start: .zero, end: CGPoint(x: 0, y: height), options: [])

    // Faint benzene rings in the corners.
    func hexagon(_ c: CGPoint, _ r: CGFloat) {
        let pts = (0..<6).map { i -> CGPoint in
            let a = CGFloat.pi / 6 + CGFloat(i) * .pi / 3
            return CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        }
        ctx.addLines(between: pts); ctx.closePath()
        let inner = pts.map { CGPoint(x: c.x + ($0.x - c.x) * 0.7, y: c.y + ($0.y - c.y) * 0.7) }
        for i in stride(from: 0, to: 6, by: 2) {
            let p = inner[i], q = inner[(i + 1) % 6]
            ctx.move(to: CGPoint(x: p.x + (q.x - p.x) * 0.15, y: p.y + (q.y - p.y) * 0.15))
            ctx.addLine(to: CGPoint(x: q.x + (p.x - q.x) * 0.15, y: q.y + (p.y - q.y) * 0.15))
        }
    }
    ctx.setStrokeColor(color(0x2BB3A3, 0.10)); ctx.setLineWidth(3); ctx.setLineJoin(.round); ctx.setLineCap(.round)
    hexagon(CGPoint(x: 590, y: 40), 64); hexagon(CGPoint(x: 40, y: 372), 52); ctx.strokePath()

    func text(_ s: String, _ font: NSFont, _ c: NSColor, centerX: CGFloat, top: CGFloat) {
        let attributed = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c])
        let size = attributed.size()
        // AppKit text draws bottom-up; flip back locally.
        ctx.saveGState()
        ctx.translateBy(x: centerX - size.width / 2, y: top + size.height); ctx.scaleBy(x: 1, y: -1)
        attributed.draw(at: .zero)
        ctx.restoreGState()
    }

    // Reaction arrow between the icons, with "conditions" below it.
    let y = appCenter.y - 8, x0 = appCenter.x + 88, x1 = applicationsCenter.x - 88
    ctx.setStrokeColor(color(0x12707F)); ctx.setFillColor(color(0x12707F))
    ctx.setLineWidth(3); ctx.setLineCap(.butt)
    ctx.move(to: CGPoint(x: x0, y: y)); ctx.addLine(to: CGPoint(x: x1 - 14, y: y)); ctx.strokePath()
    ctx.move(to: CGPoint(x: x1, y: y))
    ctx.addLine(to: CGPoint(x: x1 - 20, y: y - 8)); ctx.addLine(to: CGPoint(x: x1 - 15, y: y))
    ctx.addLine(to: CGPoint(x: x1 - 20, y: y + 8)); ctx.closePath(); ctx.fillPath()
    let mid = (x0 + x1) / 2
    let italic = NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
    text("rt, 1 s", italic, nsColor(0x0E5A86, 0.75), centerX: mid, top: y + 10)

    // First-launch note at the bottom.
    text("Then open ChemClip from Applications. The first time, Control-click it and choose Open.",
         .systemFont(ofSize: 12), nsColor(0x23415A, 0.8), centerX: width / 2, top: 336)
    text("Help is in the menu-bar icon: How ChemClip Works…",
         .systemFont(ofSize: 12), nsColor(0x23415A, 0.6), centerX: width / 2, top: 356)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: make-dmg-background.swift OUTPUT.tiff [--preview out.png]"); exit(2) }
let reps = [draw(scale: 1), draw(scale: 2)]
guard let tiff = NSBitmapImageRep.tiffRepresentationOfImageReps(in: reps, using: .lzw, factor: 0) else { exit(1) }
try tiff.write(to: URL(fileURLWithPath: args[1]))
if let i = args.firstIndex(of: "--preview"), i + 1 < args.count {
    try reps[1].representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[i + 1]))
}
