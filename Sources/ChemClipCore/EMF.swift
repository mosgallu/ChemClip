import CoreGraphics
import Foundation

/// Writes a vector drawing as a Windows Enhanced Metafile, the picture format ChemDraw for Windows
/// puts on the clipboard and Office stores unchanged on every platform.
public enum EMF {
    /// Logical units per point. 20 gives a 1/1440-inch grid, finer than any printer.
    public static let unitsPerPoint = 20.0
    private static let dpi = 72 * unitsPerPoint

    public static func make(_ drawing: VectorDrawing) -> Data {
        var w = Writer()
        let width = Int32(max(1, (drawing.size.width * unitsPerPoint).rounded(.up)))
        let height = Int32(max(1, (drawing.size.height * unitsPerPoint).rounded(.up)))
        w.record(17, [1])                           // SETMAPMODE MM_TEXT: one logical unit per reference-device pixel
        w.record(18, [1])                           // SETBKMODE TRANSPARENT
        w.record(58, [10])                          // SETMITERLIMIT
        for op in drawing.ops where !op.path.isEmpty {
            let bounds = w.bounds(op.path)
            if let fill = op.fill {
                w.record(39, [1, 0, colorref(fill), 0])         // CREATEBRUSHINDIRECT #1, BS_SOLID
                w.record(37, [1])                               // SELECTOBJECT
                w.record(19, [op.evenOdd ? 1 : 2])              // SETPOLYFILLMODE ALTERNATE / WINDING
            } else { w.record(37, [nullBrush]) }
            if let s = op.stroke {
                let cap: UInt32 = [0x200, 0, 0x100][min(max(s.cap, 0), 2)]     // PDF butt/round/square
                let join: UInt32 = [0x2000, 0, 0x1000][min(max(s.join, 0), 2)] // PDF miter/round/bevel
                let width = UInt32(max(1, (s.width * unitsPerPoint).rounded()))
                // EXTCREATEPEN #2: geometric pen, solid or PS_USERSTYLE dashes in logical units, no bitmap brush.
                let dash = s.dash.map { UInt32(max(1, ($0 * unitsPerPoint).rounded())) }
                let style: UInt32 = dash.isEmpty ? 0 : 7
                w.record(95, [2, 0, 0, 0, 0, 0x10000 | style | cap | join, width, 0, colorref(s.color), 0, UInt32(dash.count)] + dash)
                w.record(37, [2])
                w.record(58, [UInt32(max(1, s.miterLimit.rounded()))])
            } else { w.record(37, [nullPen]) }
            w.record(59, [])                                    // BEGINPATH
            w.path(op.path)
            w.record(60, [])                                    // ENDPATH
            let paint: UInt32 = op.fill != nil && op.stroke != nil ? 63 : op.fill != nil ? 62 : 64
            w.record(paint, ints: bounds)                              // STROKEANDFILLPATH / FILLPATH / STROKEPATH
            if op.fill != nil { w.record(37, [nullBrush]); w.record(40, [1]) }  // deselect before DELETEOBJECT
            if op.stroke != nil { w.record(37, [nullPen]); w.record(40, [2]) }
        }
        w.record(14, [0, 16, 20])                   // EOF
        return w.finish(width: width, height: height, handles: 3)
    }

    private static let nullBrush: UInt32 = 0x8000_0005, nullPen: UInt32 = 0x8000_0008
    private static func colorref(_ c: RGB) -> UInt32 {
        func byte(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return byte(c.r) | byte(c.g) << 8 | byte(c.b) << 16
    }

    struct Writer {
        private(set) var body = Data()
        private(set) var count = 1                  // the header counts as a record

        mutating func record(_ type: UInt32, _ values: [UInt32]) {
            append(type); append(UInt32(8 + 4 * values.count)); values.forEach { append($0) }; count += 1
        }
        mutating func record(_ type: UInt32, ints values: [Int32]) { record(type, values.map { UInt32(bitPattern: $0) }) }

        func point(_ p: CGPoint) -> (Int32, Int32) {
            (Int32(clamping: Int((p.x * unitsPerPoint).rounded())), Int32(clamping: Int((p.y * unitsPerPoint).rounded())))
        }
        func bounds(_ path: [PathElement]) -> [Int32] {
            var xs: [Int32] = [], ys: [Int32] = []
            for e in path {
                switch e {
                case .move(let p), .line(let p): let q = point(p); xs.append(q.0); ys.append(q.1)
                case .curve(let a, let b, let c): for p in [a, b, c] { let q = point(p); xs.append(q.0); ys.append(q.1) }
                case .close: break
                }
            }
            return [xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0]
        }
        /// Path records, batching consecutive lines and curves into POLYLINETO / POLYBEZIERTO.
        mutating func path(_ path: [PathElement]) {
            var i = 0
            while i < path.count {
                switch path[i] {
                case .move(let p): let q = point(p); record(27, ints: [q.0, q.1]); i += 1
                case .close: record(61, []); i += 1
                case .line:
                    var pts: [CGPoint] = []
                    while i < path.count, case .line(let p) = path[i] { pts.append(p); i += 1 }
                    polyTo(6, pts)
                case .curve:
                    var pts: [CGPoint] = []
                    while i < path.count, case .curve(let a, let b, let c) = path[i] { pts += [a, b, c]; i += 1 }
                    polyTo(5, pts)
                }
            }
        }
        private mutating func polyTo(_ type: UInt32, _ pts: [CGPoint]) {
            let q = pts.map(point)
            let box = [q.map(\.0).min()!, q.map(\.1).min()!, q.map(\.0).max()!, q.map(\.1).max()!]
            record(type, ints: box + [Int32(q.count)] + q.flatMap { [$0.0, $0.1] })
        }
        private mutating func append(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { body.append(contentsOf: $0) } }

        func finish(width: Int32, height: Int32, handles: UInt16) -> Data {
            // Reference device: 1440 dpi, A4-sized, so one logical unit is exactly 1/20 point.
            let deviceMM: (Int32, Int32) = (210, 297)
            let devicePx = (Int32((Double(deviceMM.0) / 25.4 * dpi).rounded()), Int32((Double(deviceMM.1) / 25.4 * dpi).rounded()))
            let frame = (Int32((Double(width) / dpi * 2540).rounded()), Int32((Double(height) / dpi * 2540).rounded()))
            var h = Data()
            func put(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
            func put(_ v: Int32) { put(UInt32(bitPattern: v)) }
            let headerSize: UInt32 = 108
            put(UInt32(1)); put(headerSize)
            put(Int32(0)); put(Int32(0)); put(width - 1); put(height - 1)         // rclBounds, device units, inclusive
            put(Int32(0)); put(Int32(0)); put(frame.0); put(frame.1)             // rclFrame, 0.01 mm
            put(UInt32(0x464D_4520)); put(UInt32(0x10000))                      // " EMF", version
            put(headerSize + UInt32(body.count)); put(UInt32(count))
            put(UInt32(handles))                                                 // nHandles (UInt16) + reserved (UInt16)
            put(UInt32(0)); put(UInt32(0)); put(UInt32(0))                       // description, palette
            put(devicePx.0); put(devicePx.1); put(deviceMM.0); put(deviceMM.1)
            put(UInt32(0)); put(UInt32(0)); put(UInt32(0))                       // pixel format, OpenGL
            put(deviceMM.0 * 1000); put(deviceMM.1 * 1000)                       // szlMicrometers
            return h + body
        }
    }
}
