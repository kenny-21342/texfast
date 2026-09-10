import AppKit

/// Incremental LaTeX highlighter.
///
/// Colour is applied as *temporary attributes* on the layout manager, never by
/// mutating the text storage. That matters for more than tidiness: touching the
/// storage invalidates layout, and with a scroll in flight the relayout emits
/// another bounds change, which re-enters highlighting — the loop that made
/// scrolling stutter and dragging the scroller hang.
///
/// For the same reason the font never varies. Temporary attributes that change
/// metrics would force a re-layout and shift the scroll position underfoot, so
/// comments differ by colour alone.
///
/// Only the visible range is coloured, expanded outwards to a blank line. A
/// blank line is a safe anchor because TeX forbids one inside `$…$` and `\[…\]`,
/// so the scanner always starts outside math.
final class LaTeXHighlighter {

    struct Theme {
        var comment = NSColor.systemGray
        var command = NSColor.systemBlue
        var math = NSColor.systemBrown
        var envName = NSColor.systemGreen
        var brace = NSColor.systemPurple
    }

    var theme = Theme()

    func highlight(_ storage: NSTextStorage, layout: NSLayoutManager, visible: NSRange) {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }

        let range = anchoredRange(ns, around: visible)
        guard range.length > 0 else { return }

        // Clearing the temporary colour restores the text view's own colour.
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        scan(ns, range: range) { sub, color in
            layout.setTemporaryAttributes([.foregroundColor: color], forCharacterRange: sub)
        }
    }

    /// Grow the range to the blank line before and after, so math and comment
    /// state is never mid-flight when scanning starts.
    private func anchoredRange(_ ns: NSString, around visible: NSRange) -> NSRange {
        var start = max(0, visible.location - 2000)
        var end = min(ns.length, NSMaxRange(visible) + 2000)

        let blank = "\n\n"
        if start > 0 {
            let r = ns.range(of: blank, options: .backwards, range: NSRange(location: 0, length: start))
            start = (r.location != NSNotFound) ? NSMaxRange(r) : 0
        }
        if end < ns.length {
            let r = ns.range(of: blank, options: [], range: NSRange(location: end, length: ns.length - end))
            end = (r.location != NSNotFound) ? NSMaxRange(r) : ns.length
        }
        return NSRange(location: start, length: max(0, end - start))
    }

    private func scan(_ ns: NSString, range: NSRange, emit: (NSRange, NSColor) -> Void) {
        var i = range.location
        let end = NSMaxRange(range)
        var mathStart: Int? = nil

        func flushMath(to pos: Int) {
            if let m = mathStart, pos > m {
                emit(NSRange(location: m, length: pos - m), theme.math)
            }
            mathStart = nil
        }

        while i < end {
            let c = ns.character(at: i)

            if c == 37 { // % — comment to end of line
                var j = i
                while j < end, ns.character(at: j) != 10 { j += 1 }
                emit(NSRange(location: i, length: j - i), theme.comment)
                i = j
                continue
            }

            if c == 92 { // backslash
                if i + 1 < end {
                    let next = ns.character(at: i + 1)
                    if next == 40 || next == 91 { mathStart = i; i += 2; continue }   // \( \[
                    if next == 41 || next == 93 { flushMath(to: i + 2); i += 2; continue } // \) \]
                }
                var j = i + 1
                if j < end, isLetter(ns.character(at: j)) {
                    while j < end, isLetter(ns.character(at: j)) { j += 1 }
                } else {
                    j = min(end, i + 2)   // control symbol such as \\ or \%
                }
                emit(NSRange(location: i, length: j - i), theme.command)

                let name = ns.substring(with: NSRange(location: i, length: j - i))
                if name == "\\begin" || name == "\\end", j < end, ns.character(at: j) == 123 {
                    var k = j + 1
                    while k < end, ns.character(at: k) != 125 { k += 1 }
                    if k < end { emit(NSRange(location: j + 1, length: k - j - 1), theme.envName) }
                    j = min(end, k + 1)
                }
                i = j
                continue
            }

            if c == 36 { // $
                if mathStart == nil { mathStart = i } else { flushMath(to: i + 1) }
                i += 1
                continue
            }

            if c == 123 || c == 125 { // { }
                emit(NSRange(location: i, length: 1), theme.brace)
            }
            i += 1
        }
        flushMath(to: end)
    }

    private func isLetter(_ u: unichar) -> Bool {
        (u >= 65 && u <= 90) || (u >= 97 && u <= 122)
    }
}
