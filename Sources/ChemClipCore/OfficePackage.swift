import Foundation

/// Office's own clipboard picture format (`Art::GVML ClipFormat` on Windows,
/// `com.microsoft.Art--GVML-ClipFormat` on macOS): a small OOXML zip holding one DrawingML picture.
/// Word, PowerPoint, Excel and Outlook paste it as a native picture and store the image bytes unchanged.
public enum OfficePackage {
    public static let pasteboardType = "com.microsoft.Art--GVML-ClipFormat"

    public enum Image {
        case emf(Data), png(Data)
        var part: (ext: String, mime: String, data: Data) {
            switch self { case .emf(let d): return ("emf", "image/x-emf", d); case .png(let d): return ("png", "image/png", d) }
        }
    }

    /// - Parameters:
    ///   - fallback: the picture older Office versions draw.
    ///   - svg: optional SVG that current Office (Mac and Windows) draws instead, as in Office's own SVG pictures.
    ///   - size: picture size in points.
    public static func make(_ fallback: Image, svg: Data? = nil, size: CGSize, name: String = "ChemDraw structure", description: String = "") -> Data {
        let image = fallback.part
        let cx = Int((size.width * 12700).rounded()), cy = Int((size.height * 12700).rounded())   // EMU
        let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        var defaults = [("rels", "application/vnd.openxmlformats-package.relationships+xml"), ("xml", "application/xml"), (image.ext, image.mime)]
        var imageRels = #"<Relationship Id="rId1" Type="\#(rel)/image" Target="../media/image1.\#(image.ext)"/>"#
        var blip = #"<a:blip xmlns:r="\#(rel)" r:embed="rId1"/>"#
        var media = [("clipboard/media/image1.\(image.ext)", image.data)]
        if let svg {
            defaults.append(("svg", "image/svg+xml"))
            imageRels += #"<Relationship Id="rId2" Type="\#(rel)/image" Target="../media/image2.svg"/>"#
            blip = #"<a:blip xmlns:r="\#(rel)" r:embed="rId1"><a:extLst><a:ext uri="{96DAC541-7B7A-43D3-8B79-37D633B846F1}"><asvg:svgBlip xmlns:asvg="http://schemas.microsoft.com/office/drawing/2016/SVG/main" r:embed="rId2"/></a:ext></a:extLst></a:blip>"#
            media.append(("clipboard/media/image2.svg", svg))
        }
        let types = header + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
            + defaults.map { #"<Default Extension="\#($0.0)" ContentType="\#($0.1)"/>"# }.joined()
            + #"<Override PartName="/clipboard/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/></Types>"#
        let rootRels = header + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\#(rel)/drawing" Target="clipboard/drawings/drawing1.xml"/></Relationships>"#
        let drawingRels = header + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(imageRels)</Relationships>"#
        let xfrm = #"<a:xfrm><a:off x="0" y="0"/><a:ext cx="\#(cx)" cy="\#(cy)"/></a:xfrm>"#
        let drawing = header + #"<a:graphic xmlns:a="\#(a)"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/lockedCanvas"><lc:lockedCanvas xmlns:lc="http://schemas.openxmlformats.org/drawingml/2006/lockedCanvas"><a:nvGrpSpPr><a:cNvPr id="0" name=""/><a:cNvGrpSpPr/></a:nvGrpSpPr><a:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\#(cx)" cy="\#(cy)"/><a:chOff x="0" y="0"/><a:chExt cx="\#(cx)" cy="\#(cy)"/></a:xfrm></a:grpSpPr><a:pic><a:nvPicPr><a:cNvPr id="2" name="\#(escape(name))" descr="\#(escape(description))"/><a:cNvPicPr><a:picLocks noChangeAspect="1"/></a:cNvPicPr></a:nvPicPr><a:blipFill>\#(blip)<a:stretch><a:fillRect/></a:stretch></a:blipFill><a:spPr>\#(xfrm)<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></a:spPr></a:pic></lc:lockedCanvas></a:graphicData></a:graphic>"#
        return Zip.stored([
            ("[Content_Types].xml", Data(types.utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("clipboard/drawings/drawing1.xml", Data(drawing.utf8)),
            ("clipboard/drawings/_rels/drawing1.xml.rels", Data(drawingRels.utf8)),
        ] + media)
    }

    static func escape(_ s: String) -> String {
        s.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" }.map { c -> String in
            switch c { case "&": return "&amp;"; case "<": return "&lt;"; case ">": return "&gt;"; case "\"": return "&quot;"; default: return String(c) }
        }.joined()
    }
}

/// Minimal uncompressed (stored) zip writer; all entries live in memory.
enum Zip {
    static func stored(_ entries: [(String, Data)]) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int, _ d: inout Data) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32, _ d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let dosTime = 0, dosDate = (2026 - 1980) << 9 | 1 << 5 | 1
        for (name, data) in entries {
            let offset = UInt32(out.count), crc = crc32(data), nameBytes = Data(name.utf8)
            u32(0x0403_4b50, &out); u16(20, &out); u16(0, &out); u16(0, &out); u16(dosTime, &out); u16(dosDate, &out)
            u32(crc, &out); u32(UInt32(data.count), &out); u32(UInt32(data.count), &out); u16(nameBytes.count, &out); u16(0, &out)
            out += nameBytes; out += data
            u32(0x0201_4b50, &central); u16(20, &central); u16(20, &central); u16(0, &central); u16(0, &central)
            u16(dosTime, &central); u16(dosDate, &central); u32(crc, &central); u32(UInt32(data.count), &central)
            u32(UInt32(data.count), &central); u16(nameBytes.count, &central); u16(0, &central); u16(0, &central)
            u16(0, &central); u16(0, &central); u32(0, &central); u32(offset, &central); central += nameBytes
        }
        let centralOffset = UInt32(out.count)
        out += central
        u32(0x0605_4b50, &out); u16(0, &out); u16(0, &out); u16(entries.count, &out); u16(entries.count, &out)
        u32(UInt32(central.count), &out); u32(centralOffset, &out); u16(0, &out)
        return out
    }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
