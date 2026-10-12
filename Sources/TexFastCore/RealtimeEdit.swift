import Foundation

/// A minimal replacement in UTF-8 bytes, the coordinate system of rtex's API.
/// UTF-8 scans retreat to scalar boundaries, including canonically equivalent spellings.
public struct RealtimeEdit: Equatable {
    public let start: Int
    public let end: Int
    public let text: String

    public static func between(_ old: String, _ new: String) -> RealtimeEdit? {
        // Scan contiguous UTF-8 bytes, avoiding two full arrays of Unicode scalars
        // and conversions of the unchanged prefix/suffix on every keystroke.
        let a = Array(old.utf8), b = Array(new.utf8)
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        if prefix == a.count && prefix == b.count { return nil }
        while prefix > 0, prefix < b.count, b[prefix] & 0xc0 == 0x80 { prefix -= 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix,
              a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
        while suffix > 0, a[a.count - suffix] & 0xc0 == 0x80 { suffix -= 1 }
        return RealtimeEdit(start: prefix, end: a.count - suffix,
                            text: String(decoding: b[prefix..<(b.count - suffix)], as: UTF8.self))
    }
}
