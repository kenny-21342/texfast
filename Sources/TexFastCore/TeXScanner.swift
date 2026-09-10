import Foundation
import CryptoKit

struct ImageRef {
    let nameStart: Int      // index of first char inside the braces
    let nameEnd: Int        // one past the last char inside the braces
    let name: String
}

struct Picture {
    let start: Int          // index of the backslash of \begin{...}
    let end: Int            // one past the last char of \end{...}
    let key: String         // md5 of the picture source -> content-addressed cache name
}

struct ScanResult {
    let chars: [Character]
    let images: [ImageRef]
    let pictures: [Picture]
    let beginDocument: Int  // index of the backslash of \begin{document}
}

enum TeXScanner {
    /// Environments that `tikz`'s externalization library can ship to its own PDF.
    static let pictureEnvs = ["tikzpicture", "circuitikz"]

    static func scan(_ source: String) -> ScanResult {
        let chars = Array(source)
        let commented = commentMask(chars)

        var images: [ImageRef] = []
        var pictures: [Picture] = []
        var beginDocument = -1

        var i = 0
        while i < chars.count {
            if commented[i] || chars[i] != "\\" { i += 1; continue }

            if matches(chars, i, "\\includegraphics") {
                if let ref = parseIncludegraphics(chars, from: i) {
                    images.append(ref)
                    i = ref.nameEnd + 1
                    continue
                }
            }

            if beginDocument < 0, matches(chars, i, "\\begin{document}") {
                beginDocument = i
                i += 1
                continue
            }

            for env in pictureEnvs where matches(chars, i, "\\begin{\(env)}") {
                if let end = matchingEnd(chars, from: i, env: env, commented: commented) {
                    let body = String(chars[i..<end])
                    pictures.append(Picture(start: i, end: end, key: md5Hex(body)))
                    i = end
                }
                break
            }
            i += 1
        }

        return ScanResult(chars: chars, images: images, pictures: pictures, beginDocument: beginDocument)
    }

    // MARK: - helpers

    /// True at every index that TeX would discard as a comment. A `%` only opens
    /// a comment when it is not itself escaped by a backslash.
    private static func commentMask(_ chars: [Character]) -> [Bool] {
        var mask = [Bool](repeating: false, count: chars.count)
        var inComment = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" {
                inComment = false
                i += 1
                continue
            }
            if inComment {
                mask[i] = true
                i += 1
                continue
            }
            if c == "\\" {
                // Skip the escaped character so `\%` never opens a comment.
                i += 2
                continue
            }
            if c == "%" {
                inComment = true
                mask[i] = true
            }
            i += 1
        }
        return mask
    }

    private static func matches(_ chars: [Character], _ at: Int, _ needle: String) -> Bool {
        let n = Array(needle)
        guard at + n.count <= chars.count else { return false }
        for k in 0..<n.count where chars[at + k] != n[k] { return false }
        return true
    }

    /// `\includegraphics` optionally takes `[...]` before its `{...}` argument.
    private static func parseIncludegraphics(_ chars: [Character], from: Int) -> ImageRef? {
        var j = from + "\\includegraphics".count
        // A trailing `*` or whitespace may sit before the arguments.
        while j < chars.count, chars[j] == " " || chars[j] == "\t" || chars[j] == "*" { j += 1 }
        if j < chars.count, chars[j] == "[" {
            var depth = 1
            j += 1
            while j < chars.count, depth > 0 {
                if chars[j] == "[" { depth += 1 }
                if chars[j] == "]" { depth -= 1 }
                j += 1
            }
        }
        while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
        guard j < chars.count, chars[j] == "{" else { return nil }
        let nameStart = j + 1
        var depth = 1
        j += 1
        while j < chars.count, depth > 0 {
            if chars[j] == "{" { depth += 1 }
            if chars[j] == "}" { depth -= 1; if depth == 0 { break } }
            j += 1
        }
        guard j < chars.count, depth == 0 else { return nil }
        return ImageRef(nameStart: nameStart, nameEnd: j, name: String(chars[nameStart..<j]))
    }

    /// Find the `\end{env}` that closes the `\begin{env}` at `from`, honouring nesting.
    private static func matchingEnd(_ chars: [Character], from: Int, env: String, commented: [Bool]) -> Int? {
        let openTok = "\\begin{\(env)}"
        let closeTok = "\\end{\(env)}"
        var depth = 1
        var j = from + openTok.count
        while j < chars.count {
            if commented[j] { j += 1; continue }
            if chars[j] == "\\" {
                if matches(chars, j, openTok) { depth += 1; j += openTok.count; continue }
                if matches(chars, j, closeTok) {
                    depth -= 1
                    j += closeTok.count
                    if depth == 0 { return j }
                    continue
                }
            }
            j += 1
        }
        return nil
    }

    static func md5Hex(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func md5Hex(_ d: Data) -> String {
        let digest = Insecure.MD5.hash(data: d)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
