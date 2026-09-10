import Foundation
import TexFastCore

struct PDFLocation {
    let page: Int          // 1-based
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// Wrapper around the `synctex` binary.
///
/// Everything is compiled from the shadow copy, so positions come back naming
/// that file. Both directions translate between it and the file the user is
/// actually editing.
enum SyncTeX {

    static func forward(line: Int, column: Int, shadow: URL, pdf: URL) -> PDFLocation? {
        guard let exe = Shell.which("synctex") else { return nil }
        let spec = "\(line):\(max(1, column)):\(shadow.path)"
        let r = Shell.run(exe, ["view", "-i", spec, "-o", pdf.path], cwd: pdf.deletingLastPathComponent())
        guard r.status == 0 else { return nil }

        var page: Int?, x: Double?, y: Double?, w: Double?, h: Double?
        for line in r.output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = String(parts[1])
            switch parts[0] {
            case "Page":   if page == nil { page = Int(value) }
            case "x":      if x == nil { x = Double(value) }
            case "y":      if y == nil { y = Double(value) }
            case "W":      if w == nil { w = Double(value) }
            case "H":      if h == nil { h = Double(value) }
            default: break
            }
            if page != nil && x != nil && y != nil && w != nil && h != nil { break }
        }
        guard let page, let x, let y else { return nil }
        return PDFLocation(page: page, x: x, y: y, width: w ?? 10, height: h ?? 10)
    }

    /// Returns the 1-based line in the shadow file, which shares numbering with
    /// the real source.
    static func inverse(page: Int, x: Double, y: Double, pdf: URL) -> Int? {
        guard let exe = Shell.which("synctex") else { return nil }
        let spec = "\(page):\(x):\(y):\(pdf.path)"
        let r = Shell.run(exe, ["edit", "-o", spec], cwd: pdf.deletingLastPathComponent())
        guard r.status == 0 else { return nil }
        for line in r.output.split(separator: "\n") where line.hasPrefix("Line:") {
            return Int(line.dropFirst("Line:".count))
        }
        return nil
    }
}
