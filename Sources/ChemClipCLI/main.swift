import AppKit
import ChemClipCore

let args = Array(CommandLine.arguments.dropFirst())
func usage() {
    print("""
    chemclip-tool inspect
    chemclip-tool enhance [--picture]
    chemclip-tool emf INPUT.pdf OUTPUT.emf

    inspect reports clipboard type names only. enhance adds the Office picture to the current ChemDraw copy,
    exactly as the menu-bar app does. emf converts a single-page PDF file, for testing.
    """)
}
do {
    if args == ["inspect"] { print(ClipboardEnhancer.diagnostics(.general)) }
    else if args.first == "enhance" && args.count <= 2 {
        guard let snapshot = ClipboardEnhancer.snapshot(.general) else { throw ClipError.message("No unprocessed ChemDraw copy on the clipboard.") }
        let result = try ClipboardEnhancer.enhance(snapshot, mode: args.contains("--picture") ? .picture : .vector)
        guard ClipboardEnhancer.write(result, for: snapshot, to: .general) else { throw ClipError.message("The clipboard changed during conversion.") }
        print(result.note)
    } else if args.count == 3 && args[0] == "emf" {
        let drawing = try PDFVectorReader.read(Data(contentsOf: URL(fileURLWithPath: args[1])))
        try EMF.make(drawing).write(to: URL(fileURLWithPath: args[2]))
        print("\(drawing.ops.count) paths, \(drawing.size.width)×\(drawing.size.height) pt" + (drawing.isComplete ? "" : "; unsupported: \(drawing.unsupported.sorted())"))
    } else { usage(); if !args.isEmpty { exit(2) } }
} catch { fputs("ChemClip: \(error.localizedDescription)\n", stderr); exit(1) }
