import Foundation
import TexFastCore

struct PDFLocation {
    let page: Int          // 1-based
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct SourceLocation {
    let url: URL
    let line: Int
}

/// Wrapper around the `synctex` binary.
///
/// The main document is compiled from a shadow copy, while included files keep
/// their own paths. The caller maps the shadow path back to the main source.
enum SyncTeX {

    static func forward(line: Int, column: Int, source: URL, pdf: URL) -> PDFLocation? {
        guard let exe = Shell.which("synctex") else { return nil }
        let spec = "\(line):\(max(1, column)):\(source.path)"
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

    /// Returns the input file and its 1-based line. The main input may be the
    /// shadow copy; included chapters point at their source files.
    static func inverse(page: Int, x: Double, y: Double, pdf: URL) -> SourceLocation? {
        guard let exe = Shell.which("synctex") else { return nil }
        let spec = "\(page):\(x):\(y):\(pdf.path)"
        let r = Shell.run(exe, ["edit", "-o", spec], cwd: pdf.deletingLastPathComponent())
        guard r.status == 0 else { return nil }
        var input: String?
        var lineNumber: Int?
        for line in r.output.split(separator: "\n") {
            if line.hasPrefix("Input:") { input = String(line.dropFirst("Input:".count)) }
            if line.hasPrefix("Line:") { lineNumber = Int(line.dropFirst("Line:".count)) }
            if let input, let lineNumber {
                let url = input.hasPrefix("/")
                    ? URL(fileURLWithPath: input).standardizedFileURL
                    : URL(fileURLWithPath: input, relativeTo: pdf.deletingLastPathComponent()).standardizedFileURL
                return SourceLocation(url: url.resolvingSymlinksInPath(), line: lineNumber)
            }
        }
        return nil
    }
}
