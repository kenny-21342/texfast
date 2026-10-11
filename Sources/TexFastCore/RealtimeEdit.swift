import Foundation

/// A minimal replacement in UTF-8 bytes, the coordinate system of rtex's API.
/// Comparing Unicode scalars prevents cutting a multi-byte character in half.
public struct RealtimeEdit: Equatable {
    public let start: Int
    public let end: Int
    public let text: String

    public static func between(_ old: String, _ new: String) -> RealtimeEdit? {
        if old.utf8.elementsEqual(new.utf8) { return nil }
        let a = Array(old.unicodeScalars), b = Array(new.unicodeScalars)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix,
              a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
        let head = String(String.UnicodeScalarView(a[..<prefix])).utf8.count
        let tail = String(String.UnicodeScalarView(a[(a.count - suffix)...])).utf8.count
        let replacement = String(String.UnicodeScalarView(b[prefix..<(b.count - suffix)]))
        return RealtimeEdit(start: head, end: old.utf8.count - tail, text: replacement)
    }
}
