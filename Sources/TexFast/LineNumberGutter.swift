import AppKit

/// Draws only the visible logical line numbers beside the source. The gutter
/// never changes NSTextStorage or the editor's font/layout attributes.
final class LineNumberGutter: NSView {
    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?
    private var lineStarts = [0]
    private var lineStartsAreCurrent = false

    override var isFlipped: Bool { true }

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func sourceDidChange() {
        lineStartsAreCurrent = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()

        let divider = NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height)
        NSColor.separatorColor.setFill()
        divider.fill()

        guard let textView, let scrollView,
              let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        if !lineStartsAreCurrent { rebuildLineStarts(from: textView.string) }

        let visible = scrollView.contentView.bounds
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        if layout.numberOfGlyphs == 0 {
            drawNumber(1, at: textView.textContainerOrigin.y,
                       height: textView.font?.boundingRectForFont.height ?? 16,
                       textView: textView, attributes: attributes)
            return
        }

        layout.enumerateLineFragments(forGlyphRange: glyphs) { [weak self] rect, _, _, fragmentGlyphs, _ in
            guard let self else { return }
            let character = layout.characterRange(forGlyphRange: fragmentGlyphs,
                                                   actualGlyphRange: nil).location
            let index = lineIndex(containing: character)
            guard index < lineStarts.count, lineStarts[index] == character else { return }
            drawNumber(index + 1, at: rect.minY + textView.textContainerOrigin.y,
                       height: rect.height, textView: textView, attributes: attributes)
        }
        // TextKit's final empty line has no glyphs, so its fragment is separate.
        if lineStarts.last == (textView.string as NSString).length,
           layout.extraLineFragmentTextContainer === container {
            let rect = layout.extraLineFragmentRect
            drawNumber(lineStarts.count, at: rect.minY + textView.textContainerOrigin.y,
                       height: rect.height, textView: textView, attributes: attributes)
        }
    }

    private func drawNumber(_ number: Int, at textY: CGFloat, height: CGFloat,
                            textView: NSTextView, attributes: [NSAttributedString.Key: Any]) {
        let origin = convert(NSPoint(x: 0, y: textY), from: textView)
        let label = String(number) as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: bounds.maxX - size.width - 10,
                               y: origin.y + (height - size.height) / 2),
                   withAttributes: attributes)
    }

    private func lineIndex(containing character: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= character { low = middle + 1 }
            else { high = middle }
        }
        return max(0, low - 1)
    }

    private func rebuildLineStarts(from source: String) {
        let text = source as NSString
        let length = text.length
        var units = [unichar](repeating: 0, count: length)
        if length > 0 { text.getCharacters(&units, range: NSRange(location: 0, length: length)) }
        var starts = [0]
        starts.reserveCapacity(max(16, length / 45))
        for index in units.indices {
            let character = units[index]
            if character == 10 || (character == 13 && (index + 1 == length || units[index + 1] != 10)) {
                starts.append(index + 1)
            }
        }
        lineStarts = starts
        lineStartsAreCurrent = true
    }
}
