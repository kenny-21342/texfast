import Foundation

/// Builds the transformed copy of the document that actually gets compiled.
///
/// Every edit is made *inline* — nothing is ever inserted on a line of its own —
/// so the shadow file has byte-for-byte the same line count as the original.
/// That is what keeps SyncTeX positions and log line numbers pointing at the
/// user's real `main.tex`.
enum ShadowSource {

    struct Options {
        var externalize: Bool
        var figPrefix: String            // e.g. "figs/"
        var imageRewrites: [Int: String] // index into ScanResult.images -> replacement path
        var blockedKeys: Set<String>     // picture keys that must compile inline
    }

    static func render(_ scan: ScanResult, options: Options) -> String {
        // `seq` keeps the ordering deterministic: Swift's sort is not stable, and
        // two edits can land on the same position (one picture ending exactly
        // where the next begins).
        var edits: [(pos: Int, len: Int, text: String, seq: Int)] = []
        var seq = 0
        func edit(_ pos: Int, _ len: Int, _ text: String) {
            edits.append((pos, len, text, seq)); seq += 1
        }

        for (idx, img) in scan.images.enumerated() {
            if let replacement = options.imageRewrites[idx] {
                edit(img.nameStart, img.nameEnd - img.nameStart, replacement)
            }
        }

        let activePictures = scan.pictures.filter { !options.blockedKeys.contains($0.key) }
        if options.externalize && !activePictures.isEmpty {
            // Externalization is opt-in, one picture at a time. Anything the
            // scanner does not recognise — `\tikz{...}` shorthand, pictures
            // built inside macros — stays disabled and compiles inline exactly
            // as it did before. Enabling globally instead would make tikz
            // discard those pictures ("IMAGE DISCARDED DUE TO ...") because no
            // cached PDF was ever generated for them.
            for pic in activePictures {
                edit(pic.start, 0, "\\tikzexternalenable\\tikzsetnextfilename{f\(pic.key)}")
                edit(pic.end, 0, "\\tikzexternaldisable ")
            }

            if scan.beginDocument >= 0 {
                let header = "\\usetikzlibrary{external}"
                    + "\\tikzexternalize[prefix=\(options.figPrefix),mode=list and make]"
                    + "\\tikzexternaldisable "
                edit(scan.beginDocument, 0, header)
            }
        }

        edits.sort { $0.pos == $1.pos ? $0.seq < $1.seq : $0.pos < $1.pos }

        var out = String()
        out.reserveCapacity(scan.chars.count + 64 * edits.count)
        var cursor = 0
        for e in edits {
            if e.pos > cursor { out.append(contentsOf: scan.chars[cursor..<e.pos]) }
            out += e.text
            cursor = max(cursor, e.pos + e.len)
        }
        if cursor < scan.chars.count { out.append(contentsOf: scan.chars[cursor...]) }
        return out
    }
}
