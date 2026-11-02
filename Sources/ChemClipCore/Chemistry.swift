import AppKit
import Compression

/// ChemDraw's native clipboard data carried inside an SVG picture as an XML comment:
/// `<!--chemclip:chemistry type="com.revvity.chemdraw.cdx-clipboard" data="BASE64"-->`.
/// Office stores the SVG byte for byte, so the structure survives in saved files and in copies made from Office.
/// A comment, unlike a custom `<metadata>` element, is ignored by every SVG renderer: PowerPoint fell back to
/// the low-resolution EMF when the SVG contained foreign-namespace elements. Base64 never contains "--".
public struct EmbeddedChemistry: Equatable {
    public static let namespace = "urn:chemclip:chemistry"
    public let type: String
    public let data: Data

    public init(type: String, data: Data) { self.type = type; self.data = data }

    var comment: String {
        #"<!--chemclip:chemistry type="\#(OfficePackage.escape(type))" data="\#(data.base64EncodedString())"-->"#
    }

    /// Finds embedded chemistry in an SVG. Only ChemDraw clipboard types are accepted.
    public static func find(inSVG svg: Data) -> EmbeddedChemistry? {
        let text = String(decoding: svg, as: UTF8.self)
        if let open = text.range(of: "<!--chemclip:chemistry "), let close = text[open.upperBound...].range(of: "-->") {
            let body = text[open.upperBound..<close.lowerBound]
            guard let type = attribute("type", in: body), let encoded = attribute("data", in: body) else { return nil }
            return decode(type: type, encoded)
        }
        return findLegacyMetadata(text)
    }
    private static func attribute(_ name: String, in s: Substring) -> String? {
        guard let start = s.range(of: name + "=\""), let end = s[start.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(s[start.upperBound..<end])
    }
    private static func decode(type: String, _ encoded: String) -> EmbeddedChemistry? {
        guard ClipboardEnhancer.isChemicalType(type), encoded.utf8.count <= ClipboardEnhancer.limit * 4 / 3 + 4,
              let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), !data.isEmpty else { return nil }
        return EmbeddedChemistry(type: type, data: data)
    }
    /// Pictures made by the first round-trip build used a `<metadata>` element; keep reading them.
    private static func findLegacyMetadata(_ text: String) -> EmbeddedChemistry? {
        guard let ns = text.range(of: #"xmlns:cc="\#(namespace)""#),
              let open = text[..<ns.lowerBound].range(of: "<cc:chemistry", options: .backwards),
              let tagEnd = text[ns.upperBound...].firstIndex(of: ">"),
              let close = text[tagEnd...].range(of: "</cc:chemistry>") else { return nil }
        let tag = text[open.lowerBound..<tagEnd]
        guard let typeStart = tag.range(of: #"type=""#),
              let typeEnd = tag[typeStart.upperBound...].firstIndex(of: "\"") else { return nil }
        return decode(type: String(tag[typeStart.upperBound..<typeEnd]), String(text[text.index(after: tagEnd)..<close.lowerBound]))
    }

    /// Finds embedded chemistry in an Office clipboard package (any SVG picture inside it).
    public static func find(inOfficePackage package: Data) -> EmbeddedChemistry? {
        guard let entries = try? Zip.entries(package) else { return nil }
        for entry in entries where entry.name.lowercased().hasSuffix(".svg") {
            if let svg = try? Zip.extract(entry, from: package), let found = find(inSVG: svg) { return found }
        }
        return nil
    }
}

/// When a ChemClip picture is copied from Office, puts ChemDraw's data back on the clipboard so ChemDraw pastes it
/// as an editable structure. Everything stays in memory.
public enum ClipboardRestorer {
    /// Generic bitmap types make ChemDraw paste a picture instead of its own data, so they are left out.
    static let bitmapTypes: Set<String> = ["public.png", "public.tiff", "public.jpeg", "com.compuserve.gif", "com.microsoft.bmp", "NeXT TIFF v4.0 pasteboard type"]

    public struct Restoration {
        public let changeCount: Int
        public let items: [[(type: String, data: Data)]]
        public let officeItem: Int
        public let chemistry: EmbeddedChemistry
    }

    /// Returns a restoration for an Office copy that carries ChemClip chemistry and no ChemDraw data yet.
    public static func restoration(_ board: NSPasteboard) -> Restoration? {
        let revision = board.changeCount
        let items = board.pasteboardItems ?? []
        let types = items.map { $0.types.map(\.rawValue) }
        guard !types.joined().contains(ClipboardEnhancer.marker),
              !types.joined().contains(where: ClipboardEnhancer.isChemicalType),
              let index = types.firstIndex(where: { $0.contains(OfficePackage.pasteboardType) }),
              let package = items[index].data(forType: .init(OfficePackage.pasteboardType)),
              package.count <= ClipboardEnhancer.limit,
              let chemistry = EmbeddedChemistry.find(inOfficePackage: package) else { return nil }
        var copied: [[(type: String, data: Data)]] = []
        for (item, names) in zip(items, types) {
            copied.append(names.compactMap { name in
                guard !bitmapTypes.contains(name), let data = item.data(forType: .init(name)), data.count <= ClipboardEnhancer.limit else { return nil }
                return (name, data)
            })
        }
        guard board.changeCount == revision else { return nil }
        return Restoration(changeCount: revision, items: copied, officeItem: index, chemistry: chemistry)
    }

    /// Rewrites the clipboard with Office's representations plus ChemDraw's data. Returns false if the clipboard changed.
    @discardableResult
    public static func write(_ r: Restoration, to board: NSPasteboard) -> Bool {
        guard board.changeCount == r.changeCount else { return false }
        let items: [NSPasteboardItem] = r.items.enumerated().map { index, reps in
            let item = NSPasteboardItem()
            for rep in reps { item.setData(rep.data, forType: .init(rep.type)) }
            if index == r.officeItem {
                // Older ChemDraw versions read the PerkinElmer name; current ones also read the Revvity name.
                for type in Set([r.chemistry.type, "com.perkinelmer.chemdraw.cdx-clipboard"]) { item.setData(r.chemistry.data, forType: .init(type)) }
                item.setData(Data(), forType: .init(ClipboardEnhancer.marker))
            }
            return item
        }
        board.clearContents()
        return board.writeObjects(items)
    }
}

extension Zip {
    struct Entry { let name: String; let method: UInt16; let compressedSize: Int; let size: Int; let localOffset: Int }

    /// Reads the central directory of a zip held in memory.
    static func entries(_ zip: Data) throws -> [Entry] {
        let bytes = [UInt8](zip)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard bytes.count >= 22, let end = stride(from: bytes.count - 22, through: max(0, bytes.count - 22 - 65_535), by: -1)
            .first(where: { u32($0) == 0x0605_4b50 }) else { throw ClipError.message("Not a zip package.") }
        var offset = u32(end + 16), result: [Entry] = []
        for _ in 0..<u16(end + 10) {
            guard offset + 46 <= bytes.count, u32(offset) == 0x0201_4b50 else { throw ClipError.message("Damaged zip directory.") }
            let nameLength = u16(offset + 28), extra = u16(offset + 30), comment = u16(offset + 32)
            guard offset + 46 + nameLength <= bytes.count else { throw ClipError.message("Damaged zip directory.") }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            result.append(Entry(name: name, method: UInt16(u16(offset + 10)), compressedSize: u32(offset + 20), size: u32(offset + 24), localOffset: u32(offset + 42)))
            offset += 46 + nameLength + extra + comment
        }
        return result
    }

    /// Extracts a stored or deflated entry.
    static func extract(_ entry: Entry, from zip: Data) throws -> Data {
        let bytes = [UInt8](zip)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        let header = entry.localOffset
        guard header + 30 <= bytes.count, entry.size <= ClipboardEnhancer.limit else { throw ClipError.message("Damaged zip entry.") }
        let start = header + 30 + u16(header + 26) + u16(header + 28)
        guard start + entry.compressedSize <= bytes.count else { throw ClipError.message("Damaged zip entry.") }
        let raw = Data(bytes[start..<(start + entry.compressedSize)])
        switch entry.method {
        case 0: return raw
        case 8:
            guard entry.size > 0 else { return Data() }
            var out = Data(count: entry.size)
            let written = out.withUnsafeMutableBytes { dst in
                raw.withUnsafeBytes { src in
                    compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                              src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw ClipError.message("Could not decompress zip entry.") }
            return out
        default: throw ClipError.message("Unsupported zip compression.")
        }
    }
}
