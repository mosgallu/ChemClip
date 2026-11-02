import CoreGraphics
import CoreText
import Foundation

public struct RGB: Equatable { public var r, g, b: Double }
public enum PathElement: Equatable { case move(CGPoint), line(CGPoint), curve(CGPoint, CGPoint, CGPoint), close }
public struct Stroke: Equatable {
    public var color: RGB; public var width: Double
    public var cap: Int; public var join: Int; public var miterLimit: Double   // PDF values: cap/join 0, 1, 2
    public var dash: [Double] = []                                              // on/off lengths in points
}
/// One painted path. Coordinates are points, origin at the top-left of the page, y pointing down.
public struct DrawOp: Equatable {
    public var path: [PathElement]
    public var fill: RGB?
    public var evenOdd = false
    public var stroke: Stroke?
}
public struct VectorDrawing {
    public var size: CGSize
    public var ops: [DrawOp] = []
    /// Content that could not be expressed as vector paths (images, shadings, patterns, missing glyphs).
    public var unsupported: Set<String> = []
    public var isComplete: Bool { unsupported.isEmpty }
}

/// Reads the drawing operators of a single-page PDF with CoreGraphics' own content-stream scanner.
/// Text is converted to glyph outlines from the fonts embedded in the PDF using CoreText.
public final class PDFVectorReader {
    private struct State {
        var ctm: CGAffineTransform
        var fill = RGB(r: 0, g: 0, b: 0), stroke = RGB(r: 0, g: 0, b: 0)
        var lineWidth = 1.0, cap = 0, join = 0, miter = 10.0, dash: [Double] = []
        var fillComponents = 1, strokeComponents = 1
        var font: PDFFont?, fontSize = 1.0
        var charSpacing = 0.0, wordSpacing = 0.0, hScale = 1.0, leading = 0.0, rise = 0.0, renderMode = 0
    }
    private var state: State
    private var stack: [State] = []
    private var path: [PathElement] = []
    private var current = CGPoint.zero          // current point in user space, for the v and y operators
    private var tm = CGAffineTransform.identity, tlm = CGAffineTransform.identity
    private var resources: [CGPDFDictionaryRef?] = []
    private var fonts: [CGPDFDictionaryRef: PDFFont] = [:]
    private var depth = 0
    private(set) var drawing: VectorDrawing

    public static func read(_ data: Data) throws -> VectorDrawing {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              !document.isEncrypted || document.isUnlocked else { throw ClipError.message("The clipboard PDF is invalid or locked.") }
        guard document.numberOfPages == 1, let page = document.page(at: 1) else { throw ClipError.message("Expected a single-page PDF.") }
        let reader = PDFVectorReader(page: page)
        reader.scan(CGPDFContentStreamCreateWithPage(page), resources: pageResources(page))
        return reader.drawing
    }

    private init(page: CGPDFPage) {
        let box = page.getBoxRect(.cropBox)
        drawing = VectorDrawing(size: box.size)
        // Flip into a top-left origin so every consumer gets screen-style coordinates.
        state = State(ctm: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -box.minX, ty: box.maxY))
        if page.rotationAngle % 360 != 0 { drawing.unsupported.insert("rotated page") }
    }

    /// Resources may be inherited from an ancestor Pages node.
    private static func pageResources(_ page: CGPDFPage) -> CGPDFDictionaryRef? {
        var node = page.dictionary
        while let dict = node {
            var res: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dict, "Resources", &res) { return res }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(dict, "Parent", &parent) ? parent : nil
        }
        return nil
    }

    private func scan(_ stream: CGPDFContentStreamRef, resources pageResources: CGPDFDictionaryRef?) {
        resources.append(pageResources)
        defer { resources.removeLast() }
        let scanner = CGPDFScannerCreate(stream, Self.table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    // MARK: Operator table

    private static let table: CGPDFOperatorTableRef = {
        let table = CGPDFOperatorTableCreate()!
        func on(_ name: String, _ body: @escaping CGPDFOperatorCallback) { CGPDFOperatorTableSetCallback(table, name, body) }
        on("q") { _, i in me(i).stack.append(me(i).state) }
        on("Q") { _, i in let r = me(i); if let s = r.stack.popLast() { r.state = s } }
        on("cm") { s, i in if let m = matrix(s) { me(i).state.ctm = m.concatenating(me(i).state.ctm) } }
        on("w") { s, i in if let v = num(s) { me(i).state.lineWidth = v } }
        on("J") { s, i in if let v = num(s) { me(i).state.cap = Int(v) } }
        on("j") { s, i in if let v = num(s) { me(i).state.join = Int(v) } }
        on("M") { s, i in if let v = num(s) { me(i).state.miter = v } }
        on("d") { s, i in
            var a: CGPDFArrayRef?; _ = num(s)
            guard CGPDFScannerPopArray(s, &a), let a else { return }
            var dash = (0..<CGPDFArrayGetCount(a)).compactMap { k -> Double? in var v: CGPDFReal = 0; return CGPDFArrayGetNumber(a, k, &v) ? v : nil }
            if dash.count % 2 == 1 { dash += dash }
            me(i).state.dash = dash.allSatisfy({ $0 == 0 }) ? [] : dash
        }
        on("gs") { s, i in me(i).extGState(name(s)) }
        // Path construction
        on("m") { s, i in if let p = point(s) { me(i).move(p) } }
        on("l") { s, i in if let p = point(s) { me(i).line(p) } }
        on("c") { s, i in if let p3 = point(s), let p2 = point(s), let p1 = point(s) { me(i).curve(p1, p2, p3) } }
        on("v") { s, i in if let p3 = point(s), let p2 = point(s) { me(i).curve(me(i).current, p2, p3) } }
        on("y") { s, i in if let p3 = point(s), let p1 = point(s) { me(i).curve(p1, p3, p3) } }
        on("h") { _, i in me(i).path.append(.close) }
        on("re") { s, i in
            guard let h = num(s), let w = num(s), let p = point(s) else { return }
            let r = me(i); r.move(p); r.line(CGPoint(x: p.x + w, y: p.y)); r.line(CGPoint(x: p.x + w, y: p.y + h))
            r.line(CGPoint(x: p.x, y: p.y + h)); r.path.append(.close)
        }
        // Painting
        on("f") { _, i in me(i).paint(fill: true, evenOdd: false, stroke: false) }
        on("F") { _, i in me(i).paint(fill: true, evenOdd: false, stroke: false) }
        on("f*") { _, i in me(i).paint(fill: true, evenOdd: true, stroke: false) }
        on("S") { _, i in me(i).paint(fill: false, evenOdd: false, stroke: true) }
        on("s") { _, i in me(i).path.append(.close); me(i).paint(fill: false, evenOdd: false, stroke: true) }
        on("B") { _, i in me(i).paint(fill: true, evenOdd: false, stroke: true) }
        on("B*") { _, i in me(i).paint(fill: true, evenOdd: true, stroke: true) }
        on("b") { _, i in me(i).path.append(.close); me(i).paint(fill: true, evenOdd: false, stroke: true) }
        on("b*") { _, i in me(i).path.append(.close); me(i).paint(fill: true, evenOdd: true, stroke: true) }
        on("n") { _, i in me(i).path.removeAll() }
        // Clipping is not reproduced; Quartz uses it for page bounds, which the picture frame already provides.
        on("W") { _, _ in }
        on("W*") { _, _ in }
        // Color
        on("g") { s, i in if let c = color(s, 1) { me(i).state.fill = c } }
        on("G") { s, i in if let c = color(s, 1) { me(i).state.stroke = c } }
        on("rg") { s, i in if let c = color(s, 3) { me(i).state.fill = c } }
        on("RG") { s, i in if let c = color(s, 3) { me(i).state.stroke = c } }
        on("k") { s, i in if let c = color(s, 4) { me(i).state.fill = c } }
        on("K") { s, i in if let c = color(s, 4) { me(i).state.stroke = c } }
        on("sc") { s, i in if let c = color(s, me(i).state.fillComponents) { me(i).state.fill = c } }
        on("SC") { s, i in if let c = color(s, me(i).state.strokeComponents) { me(i).state.stroke = c } }
        on("scn") { s, i in if let c = color(s, me(i).state.fillComponents) { me(i).state.fill = c } else { me(i).drawing.unsupported.insert("pattern fill") } }
        on("SCN") { s, i in if let c = color(s, me(i).state.strokeComponents) { me(i).state.stroke = c } else { me(i).drawing.unsupported.insert("pattern stroke") } }
        on("cs") { s, i in let r = me(i); r.state.fillComponents = r.components(name(s)); r.state.fill = RGB(r: 0, g: 0, b: 0) }
        on("CS") { s, i in let r = me(i); r.state.strokeComponents = r.components(name(s)); r.state.stroke = RGB(r: 0, g: 0, b: 0) }
        on("sh") { _, i in me(i).drawing.unsupported.insert("shading") }
        on("BI") { _, i in me(i).drawing.unsupported.insert("image") }
        on("Do") { s, i in me(i).xObject(name(s), scanner: s) }
        // Text
        on("BT") { _, i in me(i).tm = .identity; me(i).tlm = .identity }
        on("Tf") { s, i in let size = num(s); let n = name(s); me(i).setFont(n, size: size ?? 1) }
        on("Tc") { s, i in if let v = num(s) { me(i).state.charSpacing = v } }
        on("Tw") { s, i in if let v = num(s) { me(i).state.wordSpacing = v } }
        on("Tz") { s, i in if let v = num(s) { me(i).state.hScale = v / 100 } }
        on("TL") { s, i in if let v = num(s) { me(i).state.leading = v } }
        on("Ts") { s, i in if let v = num(s) { me(i).state.rise = v } }
        on("Tr") { s, i in if let v = num(s) { me(i).state.renderMode = Int(v) } }
        on("Td") { s, i in if let y = num(s), let x = num(s) { me(i).moveText(x, y) } }
        on("TD") { s, i in if let y = num(s), let x = num(s) { me(i).state.leading = -y; me(i).moveText(x, y) } }
        on("Tm") { s, i in if let m = matrix(s) { me(i).tm = m; me(i).tlm = m } }
        on("T*") { _, i in me(i).moveText(0, -me(i).state.leading) }
        on("Tj") { s, i in if let t = string(s) { me(i).show(t) } }
        on("'") { s, i in if let t = string(s) { me(i).moveText(0, -me(i).state.leading); me(i).show(t) } }
        on("\"") { s, i in
            guard let t = string(s), let ac = num(s), let aw = num(s) else { return }
            let r = me(i); r.state.wordSpacing = aw; r.state.charSpacing = ac; r.moveText(0, -r.state.leading); r.show(t)
        }
        on("TJ") { s, i in
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(s, &array), let array else { return }
            let r = me(i)
            for index in 0..<CGPDFArrayGetCount(array) {
                var str: CGPDFStringRef?, value: CGPDFReal = 0
                if CGPDFArrayGetString(array, index, &str), let str { r.show(bytes(str)) }
                else if CGPDFArrayGetNumber(array, index, &value) {
                    r.tm = CGAffineTransform(translationX: -value / 1000 * r.state.fontSize * r.state.hScale, y: 0).concatenating(r.tm)
                }
            }
        }
        return table
    }()

    // MARK: Paths

    private func device(_ p: CGPoint) -> CGPoint { p.applying(state.ctm) }
    private func move(_ p: CGPoint) { current = p; path.append(.move(device(p))) }
    private func line(_ p: CGPoint) { current = p; path.append(.line(device(p))) }
    private func curve(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) { current = c; path.append(.curve(device(a), device(b), device(c))) }

    private var strokeStyle: Stroke {
        let m = state.ctm
        let scale = sqrt(abs(m.a * m.d - m.b * m.c))
        return Stroke(color: state.stroke, width: max(state.lineWidth * scale, 0), cap: state.cap, join: state.join,
                      miterLimit: state.miter, dash: state.dash.map { $0 * scale })
    }
    private func paint(fill: Bool, evenOdd: Bool, stroke: Bool) {
        defer { path.removeAll() }
        guard !path.isEmpty else { return }
        drawing.ops.append(DrawOp(path: path, fill: fill ? state.fill : nil, evenOdd: evenOdd, stroke: stroke ? strokeStyle : nil))
    }

    // MARK: Resources

    private func resource(_ category: String, _ key: String?) -> CGPDFObjectRef? {
        guard let key else { return nil }
        for dict in resources.reversed() {
            guard let dict else { continue }
            var sub: CGPDFDictionaryRef?, object: CGPDFObjectRef?
            if CGPDFDictionaryGetDictionary(dict, category, &sub), let sub, CGPDFDictionaryGetObject(sub, key, &object) { return object }
        }
        return nil
    }
    /// Number of color components for a color space name (device spaces or a /ColorSpace resource).
    /// Zero means the space is not supported as a plain color (Pattern, Indexed, Separation...).
    private func components(_ key: String?) -> Int {
        switch key {
        case "DeviceGray", "G", "CalGray": return 1
        case "DeviceRGB", "RGB", "CalRGB": return 3
        case "DeviceCMYK", "CMYK": return 4
        default: break
        }
        guard let object = resource("ColorSpace", key) else { return 0 }
        var array: CGPDFArrayRef?, family: UnsafePointer<CChar>?
        if CGPDFObjectGetValue(object, .array, &array), let array, CGPDFArrayGetName(array, 0, &family), let family {
            switch String(cString: family) {
            case "CalGray": return 1
            case "CalRGB", "Lab": return 3
            case "ICCBased":
                var stream: CGPDFStreamRef?, n: CGPDFInteger = 0
                if CGPDFArrayGetStream(array, 1, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream),
                   CGPDFDictionaryGetInteger(dict, "N", &n) { return n }
            default: break
            }
        } else if CGPDFObjectGetValue(object, .name, &family), let family { return components(String(cString: family)) }
        return 0
    }
    private func extGState(_ key: String?) {
        guard let object = resource("ExtGState", key) else { return }
        var dict: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dict), let dict else { return }
        var v: CGPDFReal = 0
        if CGPDFDictionaryGetNumber(dict, "LW", &v) { state.lineWidth = v }
        if CGPDFDictionaryGetNumber(dict, "ML", &v) { state.miter = v }
        var i: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(dict, "LC", &i) { state.cap = i }
        if CGPDFDictionaryGetInteger(dict, "LJ", &i) { state.join = i }
        var soft: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(dict, "SMask", &soft) { drawing.unsupported.insert("soft mask") }
        for alpha in ["ca", "CA"] where CGPDFDictionaryGetNumber(dict, alpha, &v) && v < 0.999 { drawing.unsupported.insert("transparency") }
    }
    private func xObject(_ key: String?, scanner: CGPDFScannerRef) {
        guard let object = resource("XObject", key) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
        var subtype: UnsafePointer<CChar>?
        CGPDFDictionaryGetName(dict, "Subtype", &subtype)
        guard let subtype, String(cString: subtype) == "Form" else { drawing.unsupported.insert("image"); return }
        guard depth < 8 else { drawing.unsupported.insert("deeply nested form"); return }
        let saved = state, savedPath = path
        var m: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dict, "Matrix", &m), let m, let form = Self.matrix(m) { state.ctm = form.concatenating(state.ctm) }
        var formResources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(dict, "Resources", &formResources)
        let content = CGPDFContentStreamCreateWithStream(stream, formResources ?? dict, CGPDFScannerGetContentStream(scanner))
        depth += 1
        resources.append(formResources)
        let inner = CGPDFScannerCreate(content, Self.table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(inner); CGPDFScannerRelease(inner); CGPDFContentStreamRelease(content)
        resources.removeLast(); depth -= 1
        state = saved; path = savedPath
    }

    // MARK: Text

    private func setFont(_ key: String?, size: Double) {
        state.fontSize = size
        guard let object = resource("Font", key) else { state.font = nil; return }
        var dict: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(object, .dictionary, &dict), let dict else { state.font = nil; return }
        let id = dict
        if fonts[id] == nil { fonts[id] = PDFFont(dict) }
        state.font = fonts[id]
    }
    private func moveText(_ x: Double, _ y: Double) { tlm = CGAffineTransform(translationX: x, y: y).concatenating(tlm); tm = tlm }

    private func show(_ text: [UInt8]) {
        guard let font = state.font else { if !text.isEmpty { drawing.unsupported.insert("text without font") }; return }
        let s = state
        var glyphPath: [PathElement] = []
        for (code, isSpace) in font.codes(text) {
            let trm = CGAffineTransform(a: s.fontSize * s.hScale, b: 0, c: 0, d: s.fontSize, tx: 0, ty: s.rise)
                .concatenating(tm).concatenating(s.ctm)
            if let outline = font.outline(code) { glyphPath += elements(outline, trm) }
            else if !isSpace { drawing.unsupported.insert("missing glyph") }
            let advance = (font.width(code) / 1000 * s.fontSize + s.charSpacing + (isSpace ? s.wordSpacing : 0)) * s.hScale
            tm = CGAffineTransform(translationX: advance, y: 0).concatenating(tm)
        }
        guard !glyphPath.isEmpty else { return }
        let fill = [0, 2, 4, 6].contains(s.renderMode), stroke = [1, 2, 5, 6].contains(s.renderMode)
        guard fill || stroke else { return }
        drawing.ops.append(DrawOp(path: glyphPath, fill: fill ? s.fill : nil, stroke: stroke ? strokeStyle : nil))
    }
    private func elements(_ path: CGPath, _ t: CGAffineTransform) -> [PathElement] {
        var out: [PathElement] = []
        var last = CGPoint.zero
        path.applyWithBlock { e in
            let p = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint: last = p[0]; out.append(.move(p[0].applying(t)))
            case .addLineToPoint: last = p[0]; out.append(.line(p[0].applying(t)))
            case .addQuadCurveToPoint:
                let c1 = CGPoint(x: last.x + 2 / 3 * (p[0].x - last.x), y: last.y + 2 / 3 * (p[0].y - last.y))
                let c2 = CGPoint(x: p[1].x + 2 / 3 * (p[0].x - p[1].x), y: p[1].y + 2 / 3 * (p[0].y - p[1].y))
                last = p[1]; out.append(.curve(c1.applying(t), c2.applying(t), p[1].applying(t)))
            case .addCurveToPoint: last = p[2]; out.append(.curve(p[0].applying(t), p[1].applying(t), p[2].applying(t)))
            case .closeSubpath: out.append(.close)
            @unknown default: break
            }
        }
        return out
    }

    // MARK: Scanner helpers

    private static func me(_ info: UnsafeMutableRawPointer?) -> PDFVectorReader { Unmanaged.fromOpaque(info!).takeUnretainedValue() }
    private static func num(_ s: CGPDFScannerRef) -> Double? { var v: CGPDFReal = 0; return CGPDFScannerPopNumber(s, &v) ? Double(v) : nil }
    private static func name(_ s: CGPDFScannerRef) -> String? {
        var n: UnsafePointer<CChar>?; return CGPDFScannerPopName(s, &n) ? n.map { String(cString: $0) } : nil
    }
    private static func string(_ s: CGPDFScannerRef) -> [UInt8]? { var v: CGPDFStringRef?; return CGPDFScannerPopString(s, &v) ? v.map(bytes) : nil }
    private static func bytes(_ s: CGPDFStringRef) -> [UInt8] {
        guard let p = CGPDFStringGetBytePtr(s) else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: CGPDFStringGetLength(s)))
    }
    private static func point(_ s: CGPDFScannerRef) -> CGPoint? {
        guard let y = num(s), let x = num(s) else { return nil }; return CGPoint(x: x, y: y)
    }
    private static func matrix(_ s: CGPDFScannerRef) -> CGAffineTransform? {
        var v = [Double]()
        for _ in 0..<6 { guard let n = num(s) else { return nil }; v.insert(n, at: 0) }
        return CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
    }
    private static func matrix(_ a: CGPDFArrayRef) -> CGAffineTransform? {
        guard CGPDFArrayGetCount(a) == 6 else { return nil }
        var v = [CGPDFReal](repeating: 0, count: 6)
        for i in 0..<6 { guard CGPDFArrayGetNumber(a, i, &v[i]) else { return nil } }
        return CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
    }
    /// Pops the operands of a color operator: 1 = gray, 3 = RGB, 4 = CMYK. Other spaces return nil.
    private static func color(_ s: CGPDFScannerRef, _ count: Int) -> RGB? {
        guard [1, 3, 4].contains(count) else { return nil }
        var values = [Double]()
        for _ in 0..<count { guard let v = num(s) else { return nil }; values.insert(v, at: 0) }
        switch values.count {
        case 1: return RGB(r: values[0], g: values[0], b: values[0])
        case 3: return RGB(r: values[0], g: values[1], b: values[2])
        case 4: let k = 1 - values[3]; return RGB(r: (1 - values[0]) * k, g: (1 - values[1]) * k, b: (1 - values[2]) * k)
        default: return nil
        }
    }
}

/// A PDF font resolved to glyph outlines. Embedded font programs are preferred; installed fonts are a fallback.
final class PDFFont {
    private var ctFont: CTFont?
    private var cgFont: CGFont?
    private let twoByte: Bool
    private var firstChar = 0
    private var widths: [Double] = []
    private var defaultWidth = 1000.0
    private var cidWidths: [Int: Double] = [:]
    private var cidToGID: Data?
    private var differences: [Int: String] = [:]
    private var encoding: String.Encoding = .macOSRoman
    private var cache: [Int: CGPath?] = [:]

    init(_ dict: CGPDFDictionaryRef) {
        var subtype: UnsafePointer<CChar>?
        CGPDFDictionaryGetName(dict, "Subtype", &subtype)
        twoByte = subtype.map { String(cString: $0) } == "Type0"
        var descriptorOwner = dict
        if twoByte {
            var descendants: CGPDFArrayRef?, descendant: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(dict, "DescendantFonts", &descendants), let descendants,
               CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant {
                descriptorOwner = descendant
                var dw: CGPDFReal = 0
                if CGPDFDictionaryGetNumber(descendant, "DW", &dw) { defaultWidth = dw }
                var w: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(descendant, "W", &w), let w { cidWidths = Self.cidWidths(w) }
                var map: CGPDFStreamRef?
                if CGPDFDictionaryGetStream(descendant, "CIDToGIDMap", &map), let map {
                    var format = CGPDFDataFormat.raw
                    cidToGID = CGPDFStreamCopyData(map, &format) as Data?
                }
            }
        } else {
            var fc: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(dict, "FirstChar", &fc) { firstChar = fc }
            var w: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(dict, "Widths", &w), let w {
                widths = (0..<CGPDFArrayGetCount(w)).map { var v: CGPDFReal = 0; CGPDFArrayGetNumber(w, $0, &v); return v }
            }
            readEncoding(dict)
        }
        var descriptor: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(descriptorOwner, "FontDescriptor", &descriptor), let descriptor {
            for key in ["FontFile2", "FontFile3", "FontFile"] {
                var stream: CGPDFStreamRef?
                guard CGPDFDictionaryGetStream(descriptor, key, &stream), let stream else { continue }
                var format = CGPDFDataFormat.raw
                if let data = CGPDFStreamCopyData(stream, &format), let provider = CGDataProvider(data: data), let font = CGFont(provider) {
                    cgFont = font; ctFont = CTFontCreateWithGraphicsFont(font, 1, nil, nil); break
                }
            }
        }
        if ctFont == nil {
            var base: UnsafePointer<CChar>?
            CGPDFDictionaryGetName(dict, "BaseFont", &base)
            var name = base.map { String(cString: $0) } ?? "Helvetica"
            if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 { name = String(name[name.index(after: plus)...]) }
            let installed = CTFontCreateWithName(name as CFString, 1, nil)
            ctFont = installed; cgFont = CTFontCopyGraphicsFont(installed, nil)
        }
    }

    private func readEncoding(_ dict: CGPDFDictionaryRef) {
        var name: UnsafePointer<CChar>?, encodingDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetName(dict, "Encoding", &name), let name { encoding = Self.encoding(String(cString: name)) }
        else if CGPDFDictionaryGetDictionary(dict, "Encoding", &encodingDict), let encodingDict {
            if CGPDFDictionaryGetName(encodingDict, "BaseEncoding", &name), let name { encoding = Self.encoding(String(cString: name)) }
            var diffs: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(encodingDict, "Differences", &diffs), let diffs {
                var code = 0
                for i in 0..<CGPDFArrayGetCount(diffs) {
                    var n: CGPDFInteger = 0, glyph: UnsafePointer<CChar>?
                    if CGPDFArrayGetInteger(diffs, i, &n) { code = n }
                    else if CGPDFArrayGetName(diffs, i, &glyph), let glyph { differences[code] = String(cString: glyph); code += 1 }
                }
            }
        }
    }
    private static let asciiNames = "space exclam quotedbl numbersign dollar percent ampersand quotesingle parenleft parenright asterisk plus comma hyphen period slash zero one two three four five six seven eight nine colon semicolon less equal greater question at A B C D E F G H I J K L M N O P Q R S T U V W X Y Z bracketleft backslash bracketright asciicircum underscore grave a b c d e f g h i j k l m n o p q r s t u v w x y z braceleft bar braceright asciitilde".split(separator: " ").map(String.init)
    private static let otherNames: [UniChar: String] = [0xB0: "degree", 0xB1: "plusminus", 0xB7: "periodcentered", 0xD7: "multiply", 0x2013: "endash", 0x2014: "emdash", 0x2022: "bullet", 0x2212: "minus", 0x2019: "quoteright", 0x2018: "quoteleft", 0xB5: "mu", 0x3BC: "mu", 0xB2: "twosuperior", 0xB3: "threesuperior", 0xB9: "onesuperior", 0x2020: "dagger", 0x2021: "daggerdbl", 0x2026: "ellipsis"]
    static func glyphName(_ u: UniChar) -> String? { (32...126).contains(u) ? asciiNames[Int(u) - 32] : otherNames[u] }
    private static func encoding(_ name: String) -> String.Encoding { name == "WinAnsiEncoding" ? .windowsCP1252 : .macOSRoman }
    private static func cidWidths(_ w: CGPDFArrayRef) -> [Int: Double] {
        var out: [Int: Double] = [:], i = 0
        let count = CGPDFArrayGetCount(w)
        func number(_ index: Int) -> Double? { var v: CGPDFReal = 0; return CGPDFArrayGetNumber(w, index, &v) ? v : nil }
        while i < count, let first = number(i) {
            var list: CGPDFArrayRef?
            if CGPDFArrayGetArray(w, i + 1, &list), let list {
                for j in 0..<CGPDFArrayGetCount(list) { var v: CGPDFReal = 0; CGPDFArrayGetNumber(list, j, &v); out[Int(first) + j] = v }
                i += 2
            } else if let last = number(i + 1), let width = number(i + 2), last >= first, last - first < 65536 {
                for cid in Int(first)...Int(last) { out[cid] = width }
                i += 3
            } else { break }
        }
        return out
    }

    /// Character codes in a shown string, with whether each is a single-byte space (word spacing applies).
    func codes(_ bytes: [UInt8]) -> [(Int, Bool)] {
        guard twoByte else { return bytes.map { (Int($0), $0 == 32) } }
        return stride(from: 0, to: bytes.count - 1, by: 2).map { (Int(bytes[$0]) << 8 | Int(bytes[$0 + 1]), false) }
    }
    func width(_ code: Int) -> Double {
        if twoByte { return cidWidths[code] ?? defaultWidth }
        let index = code - firstChar
        if widths.indices.contains(index) { return widths[index] }
        if let ctFont, let glyph = glyph(code) {
            var g = glyph; return CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &g, nil, 1) * 1000
        }
        return 0
    }
    func outline(_ code: Int) -> CGPath? {
        if let hit = cache[code] { return hit }
        let path = glyph(code).flatMap { g in ctFont.flatMap { CTFontCreatePathForGlyph($0, g, nil) } }
        cache[code] = path
        return path
    }
    private func glyph(_ code: Int) -> CGGlyph? {
        guard let ctFont else { return nil }
        if twoByte {
            if let map = cidToGID, map.count >= code * 2 + 2 { return CGGlyph(map[code * 2]) << 8 | CGGlyph(map[code * 2 + 1]) }
            return CGGlyph(truncatingIfNeeded: code)
        }
        if let name = differences[code], let cgFont {
            let g = cgFont.getGlyphWithGlyphName(name: name as CFString)
            if g != 0 { return g }
        }
        var candidates: [UniChar] = []
        let unicode = String(bytes: [UInt8(truncatingIfNeeded: code)], encoding: encoding)?.utf16.first
        if let unicode { candidates.append(unicode) }
        candidates += [UniChar(0xF000 + code), UniChar(code)]   // symbolic TrueType conventions
        for var c in candidates {
            var g: CGGlyph = 0
            if CTFontGetGlyphsForCharacters(ctFont, &c, &g, 1), g != 0 { return g }
        }
        // Bare CFF/Type 1 programs often have no character map, only glyph names.
        if let unicode, let name = Self.glyphName(unicode), let cgFont {
            let g = cgFont.getGlyphWithGlyphName(name: name as CFString)
            if g != 0 { return g }
        }
        return nil
    }
}
