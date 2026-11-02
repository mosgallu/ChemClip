import XCTest
import AppKit
import CoreGraphics
import CoreText
@testable import ChemClipCore

final class CoreTests: XCTestCase {
    let chemType = "com.revvity.chemdraw.cdx-clipboard"

    func board() -> NSPasteboard { NSPasteboard.withUniqueName() }
    func item(_ values: [String: Data]) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for (type, value) in values { item.setData(value, forType: .init(type)) }; return item
    }

    /// A PDF drawn by Quartz, like ChemDraw's clipboard PDF: filled bond, dashed and solid strokes, a curve and text.
    func samplePDF(text: String = "NO2", font: String = "Helvetica") -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 10, y: 10, width: 30, height: 5))
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.setLineWidth(1); ctx.setLineDash(phase: 0, lengths: [2, 2])
        ctx.move(to: CGPoint(x: 10, y: 50)); ctx.addLine(to: CGPoint(x: 190, y: 50)); ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: []); ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 10, y: 90)); ctx.addCurve(to: CGPoint(x: 100, y: 90), control1: CGPoint(x: 40, y: 60), control2: CGPoint(x: 70, y: 60))
        ctx.strokePath()
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName(font as CFString, 12, nil)]))
        ctx.textPosition = CGPoint(x: 120, y: 20)
        CTLineDraw(line, ctx)
        ctx.endPDFPage(); ctx.closePDF()
        return data as Data
    }

    // MARK: PDF reading

    func testReadsPathsColorsDashesAndText() throws {
        let drawing = try PDFVectorReader.read(samplePDF())
        XCTAssertEqual(drawing.size, CGSize(width: 200, height: 100))
        XCTAssertTrue(drawing.isComplete, "\(drawing.unsupported)")
        XCTAssertTrue(drawing.ops.contains { $0.fill == RGB(r: 1, g: 0, b: 0) })
        let dashed = try XCTUnwrap(drawing.ops.first { $0.stroke?.dash.isEmpty == false })
        XCTAssertEqual(dashed.stroke?.dash, [2, 2]); XCTAssertEqual(dashed.stroke?.color, RGB(r: 0, g: 0, b: 1))
        XCTAssertTrue(drawing.ops.contains { $0.stroke?.cap == 1 && $0.path.contains { if case .curve = $0 { return true }; return false } })
        // Text becomes filled glyph outlines in the right place (top-left origin: y = 100 - 20 baseline).
        let glyphs = drawing.ops.filter { $0.fill == RGB(r: 0, g: 0, b: 0) }
        XCTAssertFalse(glyphs.isEmpty)
        let ys = glyphs.flatMap(\.path).compactMap { e -> CGFloat? in if case .move(let p) = e { return p.y }; return nil }
        XCTAssertTrue(ys.allSatisfy { $0 > 60 && $0 < 81 }, "\(ys)")
    }
    func testFlipsToTopLeftOrigin() throws {
        let drawing = try PDFVectorReader.read(samplePDF())
        let red = try XCTUnwrap(drawing.ops.first { $0.fill == RGB(r: 1, g: 0, b: 0) })
        let points = red.path.compactMap { e -> CGPoint? in if case .move(let p) = e { return p }; if case .line(let p) = e { return p }; return nil }
        XCTAssertEqual(points.map(\.y).min()!, 85, accuracy: 0.001)   // 100 - (10 + 5)
        XCTAssertEqual(points.map(\.x).min()!, 10, accuracy: 0.001)
    }
    func testRasterImagesAreReportedNotHidden() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 50, height: 50)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        let bitmap = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        ctx.draw(bitmap.makeImage()!, in: CGRect(x: 0, y: 0, width: 50, height: 50))
        ctx.endPDFPage(); ctx.closePDF()
        XCTAssertTrue(try PDFVectorReader.read(data as Data).unsupported.contains("image"))
    }
    func testRejectsInvalidAndMultiPagePDF() {
        XCTAssertThrowsError(try PDFVectorReader.read(Data("%PDF-1.4 nonsense".utf8)))
        let data = NSMutableData()
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: nil, nil)!
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()
        XCTAssertThrowsError(try PDFVectorReader.read(data as Data))
    }

    // MARK: Writers

    func testEMFStructure() throws {
        let emf = EMF.make(try PDFVectorReader.read(samplePDF()))
        func u32(_ o: Int) -> UInt32 { emf.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        XCTAssertEqual(u32(0), 1); XCTAssertEqual(u32(40), 0x464D_4520)
        XCTAssertEqual(Int(u32(48)), emf.count)
        XCTAssertEqual(Int32(bitPattern: u32(16)), 200 * 20 - 1)                 // rclBounds right
        XCTAssertEqual(Int32(bitPattern: u32(32)), Int32((200.0 / 72 * 2540).rounded()))   // rclFrame right, 0.01 mm
        var offset = 0, records = 0, last: UInt32 = 0, types = Set<UInt32>()
        while offset < emf.count {
            last = u32(offset); let size = Int(u32(offset + 4))
            XCTAssertTrue(size >= 8 && size % 4 == 0); offset += size; records += 1; types.insert(last)
        }
        XCTAssertEqual(offset, emf.count); XCTAssertEqual(records, Int(u32(52))); XCTAssertEqual(last, 14)
        XCTAssertTrue(types.isSuperset(of: [62, 64, 5, 95]))                    // fill, stroke, bezier, pen
    }
    func testSVGIsStaticPathsOnly() throws {
        let drawing = try PDFVectorReader.read(samplePDF())
        let svg = String(decoding: SVG.make(drawing), as: UTF8.self)
        XCTAssertTrue(svg.hasPrefix(#"<svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="200pt" height="100pt" viewBox="0 0 200 100">"#))
        XCTAssertEqual(svg.components(separatedBy: "<path ").count - 1, drawing.ops.count)
        XCTAssertTrue(svg.contains(#"stroke-dasharray="2 2""#))
        for banned in ["<text", "<image", "<script", "href"] { XCTAssertFalse(svg.contains(banned)) }
        XCTAssertTrue(XMLParser(data: Data(svg.utf8)).parse())
        XCTAssertEqual(SVG.n(1.23049), "1.23"); XCTAssertEqual(SVG.n(-0.0001), "0"); XCTAssertEqual(SVG.n(5), "5")
    }
    func testOfficePackageIsValidZip() throws {
        let package = OfficePackage.make(.emf(Data([1, 2, 3])), svg: Data("<svg/>".utf8), size: CGSize(width: 72, height: 36),
                                         description: "a < b & \"c\"")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try package.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); p.arguments = ["-t", "-q", url.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let text = String(decoding: package, as: UTF8.self)
        XCTAssertTrue(text.contains(#"relationships/drawing" Target="clipboard/drawings/drawing1.xml""#))
        XCTAssertTrue(text.contains(#"<a:ext cx="914400" cy="457200"/>"#))   // 1 in × 0.5 in
        XCTAssertTrue(text.contains("svgBlip")); XCTAssertTrue(text.contains("a &lt; b &amp; &quot;c&quot;"))
        XCTAssertEqual(Zip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    // MARK: Clipboard

    func testRecognizesChemDrawTypes() {
        for value in [chemType, "com.perkinelmer.chemdraw.cdx-clipboard", "com.cambridgesoft.cdx", "com.revvity.cdxml"] {
            XCTAssertTrue(ClipboardEnhancer.isChemicalType(value))
        }
        XCTAssertFalse(ClipboardEnhancer.isChemicalType("com.adobe.pdf"))
        XCTAssertFalse(ClipboardEnhancer.isChemicalType("evil.chemdraw.cdx"))
    }
    func testIgnoresNonChemDrawCopies() {
        let b = board(); defer { b.releaseGlobally() }
        b.writeObjects([item(["com.adobe.pdf": samplePDF()])])
        XCTAssertNil(ClipboardEnhancer.snapshot(b))
        b.clearContents(); b.writeObjects([item([chemType: Data([1])])])
        XCTAssertNil(ClipboardEnhancer.snapshot(b))
        // Chemical data on one item and a PDF on another must not be combined.
        b.clearContents(); b.writeObjects([item([chemType: Data([1])]), item(["com.adobe.pdf": samplePDF()])])
        XCTAssertNil(ClipboardEnhancer.snapshot(b))
    }
    func testEnhancesInPlaceKeepingEveryOriginalRepresentation() throws {
        let b = board(); defer { b.releaseGlobally() }
        let original = [chemType: Data([7, 7]), "com.adobe.pdf": samplePDF(), "org.opensmiles.smiles": Data("CCO".utf8)]
        b.writeObjects([item(original)])
        let snapshot = try XCTUnwrap(ClipboardEnhancer.snapshot(b))
        XCTAssertEqual(snapshot.smiles, "CCO")
        let result = try ClipboardEnhancer.enhance(snapshot)
        XCTAssertTrue(result.vector)
        XCTAssertTrue(ClipboardEnhancer.write(result, for: snapshot, to: b))
        let types = b.pasteboardItems!.first!.types.map(\.rawValue)
        XCTAssertEqual(types.first, OfficePackage.pasteboardType)       // Office's format leads
        for (type, data) in original { XCTAssertEqual(b.data(forType: .init(type)), data) }
        XCTAssertTrue(types.contains(ClipboardEnhancer.marker))
        // A generic image type would make ChemDraw paste a picture instead of its editable structure.
        XCTAssertFalse(types.contains { ["public.png", "public.tiff", "public.jpeg"].contains($0) })
        XCTAssertNil(ClipboardEnhancer.snapshot(b), "our own rewrite must not be processed again")
    }
    func testPictureModeGivesOfficeA600dpiImage() throws {
        let b = board(); defer { b.releaseGlobally() }
        b.writeObjects([item([chemType: Data([1]), "com.adobe.pdf": samplePDF()])])
        let result = try ClipboardEnhancer.enhance(try XCTUnwrap(ClipboardEnhancer.snapshot(b)), mode: .picture)
        XCTAssertFalse(result.vector)
        let text = String(decoding: result.office, as: UTF8.self)
        XCTAssertTrue(text.contains("image1.png")); XCTAssertFalse(text.contains("svgBlip"))
        XCTAssertTrue(text.contains(#"<a:ext cx="2540000" cy="1270000"/>"#))   // still placed at the drawing's 200 × 100 pt
        let png = try ClipboardEnhancer.rasterize(samplePDF(), dpi: 600)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(rep.pixelsWide, Int((200 * 600 / 72.0).rounded(.up)))
        XCTAssertEqual(rep.size.width, 200, accuracy: 0.5)                   // 600 dpi metadata: 200 pt wide
    }
    func testDoesNotOverwriteANewerCopy() throws {
        let b = board(); defer { b.releaseGlobally() }
        b.writeObjects([item([chemType: Data([1]), "com.adobe.pdf": samplePDF()])])
        let snapshot = try XCTUnwrap(ClipboardEnhancer.snapshot(b))
        let result = try ClipboardEnhancer.enhance(snapshot)
        b.clearContents(); b.setString("newer", forType: .string)
        XCTAssertFalse(ClipboardEnhancer.write(result, for: snapshot, to: b))
        XCTAssertEqual(b.string(forType: .string), "newer")
    }
    func testIncompleteVectorFallsBackToHighResolutionPicture() throws {
        var drawing = VectorDrawing(size: CGSize(width: 10, height: 10)); drawing.unsupported = ["image"]
        XCTAssertFalse(drawing.isComplete)
        let b = board(); defer { b.releaseGlobally() }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 50, height: 50)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil); ctx.endPDFPage(); ctx.closePDF()            // nothing drawable
        b.writeObjects([item([chemType: Data([1]), "com.adobe.pdf": data as Data])])
        let result = try ClipboardEnhancer.enhance(try XCTUnwrap(ClipboardEnhancer.snapshot(b)))
        XCTAssertFalse(result.vector)
        XCTAssertTrue(String(decoding: result.office, as: UTF8.self).contains("image1.png"))
    }
}

final class ChemistryTests: XCTestCase {
    let chemType = "com.revvity.chemdraw.cdx-clipboard"
    let cdx = Data((0..<300).map { UInt8($0 % 256) })

    func samplePDF() -> Data { CoreTests().samplePDF() }
    func item(_ values: [String: Data]) -> NSPasteboardItem { CoreTests().item(values) }

    func testSVGCarriesChemistryAndStaysValid() throws {
        let drawing = try PDFVectorReader.read(samplePDF())
        let svg = SVG.make(drawing, chemistry: EmbeddedChemistry(type: chemType, data: cdx))
        XCTAssertTrue(XMLParser(data: svg).parse())
        XCTAssertEqual(EmbeddedChemistry.find(inSVG: svg), EmbeddedChemistry(type: chemType, data: cdx))
        XCTAssertNil(EmbeddedChemistry.find(inSVG: SVG.make(drawing)))
        // Nothing a renderer could trip over: the only non-path content is a comment.
        XCTAssertFalse(String(decoding: svg, as: UTF8.self).contains("<metadata"))
        XCTAssertTrue(String(decoding: svg, as: UTF8.self).contains("<!--chemclip:chemistry "))
        // Pictures from the earlier <metadata> format are still recognized.
        let legacy = Data(#"<svg xmlns="http://www.w3.org/2000/svg"><metadata><cc:chemistry xmlns:cc="urn:chemclip:chemistry" type="\#(chemType)">\#(cdx.base64EncodedString())</cc:chemistry></metadata></svg>"#.utf8)
        XCTAssertEqual(EmbeddedChemistry.find(inSVG: legacy)?.data, cdx)
        // Only ChemDraw types are ever restored.
        let other = SVG.make(drawing, chemistry: EmbeddedChemistry(type: "public.utf8-plain-text", data: cdx))
        XCTAssertNil(EmbeddedChemistry.find(inSVG: other))
    }
    func testEnhancedCopyEmbedsTheCDX() throws {
        let b = NSPasteboard.withUniqueName(); defer { b.releaseGlobally() }
        b.writeObjects([item([chemType: cdx, "com.adobe.pdf": samplePDF()])])
        let result = try ClipboardEnhancer.enhance(try XCTUnwrap(ClipboardEnhancer.snapshot(b)))
        XCTAssertEqual(EmbeddedChemistry.find(inOfficePackage: result.office), EmbeddedChemistry(type: chemType, data: cdx))
    }
    func testFindsChemistryInADeflatedOfficePackage() throws {
        // Office may compress its own packages; build one with the system zip tool.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("clipboard/media"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let svg = SVG.make(try PDFVectorReader.read(samplePDF()), chemistry: EmbeddedChemistry(type: chemType, data: cdx))
        try svg.write(to: dir.appendingPathComponent("clipboard/media/image2.svg"))
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); p.currentDirectoryURL = dir
        p.arguments = ["-q", "-9", "-r", "pkg.zip", "clipboard"]; try p.run(); p.waitUntilExit()
        let package = try Data(contentsOf: dir.appendingPathComponent("pkg.zip"))
        XCTAssertEqual(try Zip.entries(package).first { $0.name.hasSuffix(".svg") }?.method, 8)
        XCTAssertEqual(EmbeddedChemistry.find(inOfficePackage: package)?.data, cdx)
        XCTAssertNil(EmbeddedChemistry.find(inOfficePackage: Data("not a zip".utf8)))
    }
    func testOfficeCopyGetsChemDrawDataBack() throws {
        let b = NSPasteboard.withUniqueName(); defer { b.releaseGlobally() }
        let svg = SVG.make(try PDFVectorReader.read(samplePDF()), chemistry: EmbeddedChemistry(type: chemType, data: cdx))
        let package = OfficePackage.make(.emf(Data([1])), svg: svg, size: CGSize(width: 10, height: 10))
        let pdf = samplePDF()
        b.writeObjects([item([OfficePackage.pasteboardType: package, "com.adobe.pdf": pdf, "public.tiff": Data([9])])])
        let r = try XCTUnwrap(ClipboardRestorer.restoration(b))
        XCTAssertTrue(ClipboardRestorer.write(r, to: b))
        XCTAssertEqual(b.data(forType: .init(chemType)), cdx)
        XCTAssertEqual(b.data(forType: .init("com.perkinelmer.chemdraw.cdx-clipboard")), cdx)
        XCTAssertEqual(b.data(forType: .init(OfficePackage.pasteboardType)), package)   // Office can still paste it
        XCTAssertEqual(b.data(forType: .init("com.adobe.pdf")), pdf)
        XCTAssertNil(b.data(forType: .init("public.tiff")), "bitmaps would make ChemDraw paste a picture")
        XCTAssertNil(ClipboardRestorer.restoration(b)); XCTAssertNil(ClipboardEnhancer.snapshot(b))
    }
    func testOrdinaryOfficeCopiesAreLeftAlone() {
        let b = NSPasteboard.withUniqueName(); defer { b.releaseGlobally() }
        let package = OfficePackage.make(.png(Data([1])), size: CGSize(width: 10, height: 10))
        b.writeObjects([item([OfficePackage.pasteboardType: package, "public.tiff": Data([9])])])
        XCTAssertNil(ClipboardRestorer.restoration(b))
        XCTAssertEqual(b.data(forType: .init("public.tiff")), Data([9]))
    }
}
