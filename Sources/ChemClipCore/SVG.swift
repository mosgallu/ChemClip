import CoreGraphics
import Foundation

/// Writes a vector drawing as a static SVG: paths only, no text, fonts, images or scripts.
public enum SVG {
    /// - Parameter chemistry: ChemDraw's native clipboard data, carried in a comment so a copy from Office can be
    ///   pasted back into ChemDraw as an editable structure (see `EmbeddedChemistry`).
    public static func make(_ drawing: VectorDrawing, chemistry: EmbeddedChemistry? = nil) -> Data {
        let w = n(drawing.size.width), h = n(drawing.size.height)
        var out = #"<svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="\#(w)pt" height="\#(h)pt" viewBox="0 0 \#(w) \#(h)">"#
        if let chemistry { out += chemistry.comment }
        for op in drawing.ops where !op.path.isEmpty {
            out += #"<path d="\#(d(op.path))""#
            if let fill = op.fill {
                out += #" fill="\#(hex(fill))""#
                if op.evenOdd { out += #" fill-rule="evenodd""# }
            } else { out += #" fill="none""# }
            if let s = op.stroke {
                out += #" stroke="\#(hex(s.color))" stroke-width="\#(n(s.width))""#
                out += #" stroke-linecap="\#(["butt", "round", "square"][min(max(s.cap, 0), 2)])""#
                out += #" stroke-linejoin="\#(["miter", "round", "bevel"][min(max(s.join, 0), 2)])""#
                if s.join == 0 { out += #" stroke-miterlimit="\#(n(max(1, s.miterLimit)))""# }
                if !s.dash.isEmpty { out += #" stroke-dasharray="\#(s.dash.map(n).joined(separator: " "))""# }
            }
            out += "/>"
        }
        return Data((out + "</svg>").utf8)
    }

    static func d(_ path: [PathElement]) -> String {
        path.map { e -> String in
            switch e {
            case .move(let p): return "M\(n(p.x)) \(n(p.y))"
            case .line(let p): return "L\(n(p.x)) \(n(p.y))"
            case .curve(let a, let b, let c): return "C\(n(a.x)) \(n(a.y)) \(n(b.x)) \(n(b.y)) \(n(c.x)) \(n(c.y))"
            case .close: return "Z"
            }
        }.joined()
    }
    /// Three decimals of a point (~0.35 µm) without trailing zeros.
    static func n(_ v: Double) -> String {
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }
    private static func hex(_ c: RGB) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(c.r), byte(c.g), byte(c.b))
    }
}
