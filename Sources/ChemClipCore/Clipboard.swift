import AppKit
import ImageIO
import UniformTypeIdentifiers

public enum ClipError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

/// A copy of every pasteboard item and representation, taken in one pass.
public struct ClipboardSnapshot {
    public let changeCount: Int
    public let items: [[(type: String, data: Data)]]
    /// Index of the item holding ChemDraw data and its PDF drawing.
    public let chemItem: Int
    public var pdf: Data { items[chemItem].first { ClipboardEnhancer.pdfTypes.contains($0.type) }!.data }
    /// The first ChemDraw-native representation (CDX) on the ChemDraw item.
    public var chemistry: EmbeddedChemistry? {
        items[chemItem].first { ClipboardEnhancer.isChemicalType($0.type) && !$0.data.isEmpty }.map { EmbeddedChemistry(type: $0.type, data: $0.data) }
    }
    public var smiles: String? {
        items[chemItem].first { $0.type == "org.opensmiles.smiles" }.map { String(decoding: $0.data, as: UTF8.self) }
    }
}

public struct Enhancement {
    public let office: Data
    public let vector: Bool
    public let note: String
}

/// How the picture is handed to Office.
public enum OfficeMode: String {
    /// SVG with a vector EMF fallback: sharp at any zoom, exports as SVG/PDF. Office's own PNG export is low resolution.
    case vector
    /// A 600 dpi bitmap: what Office's Save as Picture → PNG then exports.
    case picture
}

/// Adds Office-native pictures to a ChemDraw copy. Everything stays in memory: no files are written.
public enum ClipboardEnhancer {
    public static let limit = 32 * 1024 * 1024
    public static let marker = "local.chemclip.enhanced"
    public static let pdfTypes = ["com.adobe.pdf", "Apple PDF pasteboard type"]
    public static let pngDPI = 600.0

    public static func isChemicalType(_ type: String) -> Bool {
        let t = type.lowercased()
        return ["com.revvity.", "com.perkinelmer.", "com.cambridgesoft."].contains(where: t.hasPrefix)
            && (t.contains("cdx") || t.contains("chemdraw.structure"))
    }

    /// Returns a snapshot only for an unprocessed ChemDraw copy that carries a PDF drawing on the same item.
    public static func snapshot(_ board: NSPasteboard) -> ClipboardSnapshot? {
        let revision = board.changeCount
        let items = board.pasteboardItems ?? []
        let types = items.map { $0.types.map(\.rawValue) }
        guard !types.joined().contains(marker),
              let chem = types.firstIndex(where: { t in t.contains(where: isChemicalType) && t.contains(where: pdfTypes.contains) })
        else { return nil }
        var copied: [[(type: String, data: Data)]] = []
        for (item, names) in zip(items, types) {
            var reps: [(type: String, data: Data)] = []
            for name in names {
                guard let data = item.data(forType: .init(name)) else { continue }
                guard data.count <= limit else { return nil }
                reps.append((name, data))
            }
            copied.append(reps)
        }
        guard board.changeCount == revision,
              copied[chem].contains(where: { pdfTypes.contains($0.type) && !$0.data.isEmpty }) else { return nil }
        return ClipboardSnapshot(changeCount: revision, items: copied, chemItem: chem)
    }

    /// Converts the ChemDraw PDF. Safe to call off the main thread.
    public static func enhance(_ snapshot: ClipboardSnapshot, mode: OfficeMode = .vector) throws -> Enhancement {
        let pdf = snapshot.pdf
        let drawing = try PDFVectorReader.read(pdf)
        let description = snapshot.smiles.map { "ChemDraw structure: " + $0 } ?? "ChemDraw structure"
        if mode == .vector && drawing.isComplete && !drawing.ops.isEmpty {
            let office = OfficePackage.make(.emf(EMF.make(drawing)), svg: SVG.make(drawing, chemistry: snapshot.chemistry), size: drawing.size, description: description)
            return Enhancement(office: office, vector: true, note: "vector graphic")
        }
        // Requested, or content EMF/SVG cannot express faithfully: a high-resolution bitmap rather than a lossy vector.
        let office = OfficePackage.make(.png(try rasterize(pdf, dpi: pngDPI)), size: drawing.size, description: description)
        let reasons = drawing.unsupported.sorted().joined(separator: ", ")
        let note = mode == .picture ? "\(Int(pngDPI)) dpi picture"
            : "\(Int(pngDPI)) dpi picture, because the drawing contains \(reasons.isEmpty ? "no vector paths" : reasons)"
        return Enhancement(office: office, vector: false, note: note)
    }

    /// Rewrites the clipboard with the original representations plus the Office picture.
    /// No generic image type (PNG, TIFF) is added: ChemDraw would paste it instead of its own editable data.
    /// Returns false, changing nothing, if another copy happened since the snapshot.
    @discardableResult
    public static func write(_ e: Enhancement, for snapshot: ClipboardSnapshot, to board: NSPasteboard) -> Bool {
        guard board.changeCount == snapshot.changeCount else { return false }
        let items: [NSPasteboardItem] = snapshot.items.enumerated().map { index, reps in
            let item = NSPasteboardItem()
            if index == snapshot.chemItem {
                // Office reads its own format first; ChemDraw, MOL, SMILES and PDF stay for other apps.
                item.setData(e.office, forType: .init(OfficePackage.pasteboardType))
            }
            for rep in reps { item.setData(rep.data, forType: .init(rep.type)) }
            if index == snapshot.chemItem { item.setData(Data(), forType: .init(marker)) }
            return item
        }
        board.clearContents()
        return board.writeObjects(items)
    }

    static func rasterize(_ pdf: Data, dpi: Double) throws -> Data {
        guard let provider = CGDataProvider(data: pdf as CFData), let doc = CGPDFDocument(provider), let page = doc.page(at: 1)
        else { throw ClipError.message("The clipboard PDF is invalid.") }
        let box = page.getBoxRect(.cropBox)
        // Cap very large drawings at ~100 megapixels.
        let scale = min(dpi / 72, sqrt(100_000_000 / max(box.width * box.height, 1)))
        let w = max(1, Int((box.width * scale).rounded(.up))), h = max(1, Int((box.height * scale).rounded(.up)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ClipError.message("Not enough memory to render the picture.") }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { throw ClipError.message("Could not render the picture.") }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { throw ClipError.message("PNG encoder unavailable.") }
        let effectiveDPI = scale * 72
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: effectiveDPI, kCGImagePropertyDPIHeight: effectiveDPI] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ClipError.message("Could not encode the PNG.") }
        return out as Data
    }

    public static func diagnostics(_ board: NSPasteboard) -> String {
        let rows = (board.pasteboardItems ?? []).enumerated().map { index, item in
            "Item \(index + 1):\n" + item.types.map { "  " + $0.rawValue }.joined(separator: "\n")
        }
        return "Clipboard change count: \(board.changeCount)\n" + (rows.isEmpty ? "No readable items." : rows.joined(separator: "\n"))
    }
}
