import AppKit
import CoreGraphics

/// Finds visual TeX constructs only after the pointer has rested on source.
/// Ranges are UTF-16 so they line up with NSTextView.
private struct HoverTarget {
    let range: NSRange

    static func at(_ index: Int, in source: NSString) -> HoverTarget? {
        // Keep regex work local even in very long notes. Tables can be longer
        // than equations, so leave room on either side of the hovered row.
        let start = max(0, index - 12_000)
        let range = NSRange(location: start, length: min(source.length - start, 24_000))
        let excerpt = source.substring(with: range) as NSString
        let local = index - start

        let imagePattern = #"\\includegraphics(?:\s*\[[^\]]*\])?\s*\{([^{}]+)\}"#
        if let match = matching(imagePattern, around: local, in: excerpt),
           !isCommented(match.range.location, in: excerpt) {
            return HoverTarget(range: NSRange(location: start + match.range.location, length: match.range.length))
        }

        let tablePattern = #"\\begin\{(tabularx|tabular)\}(?s:.{1,20000}?)\\end\{\1\}"#
        if let match = matching(tablePattern, around: local, in: excerpt),
           !isCommented(match.range.location, in: excerpt) {
            let startOffset = start + match.range.location
            return HoverTarget(range: NSRange(location: startOffset, length: match.range.length))
        }

        let patterns = [
            #"\\begin\{(equation\*?|align\*?|alignat\*?|flalign\*?|gather\*?|multline\*?|displaymath|math|tikzpicture|circuitikz|pgfpicture)\}(?s:.{1,6000}?)\\end\{\1\}"#,
            #"\\\[(?s:.{1,6000}?)\\\]"#,
            #"\\\((?s:.{1,2000}?)\\\)"#,
            #"(?<!\\)(?<!\$)\$\$(?s:.{1,6000}?)\$\$"#,
            #"(?<!\\)(?<!\$)\$(?!\$)(?s:[^$]{1,2000}?)\$(?!\$)"#
        ]
        for pattern in patterns {
            guard let match = matching(pattern, around: local, in: excerpt),
                  !isCommented(match.range.location, in: excerpt) else { continue }
            let full = NSRange(location: start + match.range.location, length: match.range.length)
            return HoverTarget(range: full)
        }
        return nil
    }

    private static func matching(_ pattern: String, around index: Int, in text: NSString) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
            .first { NSLocationInRange(index, $0.range) }
    }

    private static func isCommented(_ offset: Int, in text: NSString) -> Bool {
        let line = text.lineRange(for: NSRange(location: offset, length: 0))
        var slashes = 0
        for i in line.location..<offset {
            switch text.character(at: i) {
            case 92: slashes += 1
            case 37: if slashes.isMultiple(of: 2) { return true }; slashes = 0
            default: slashes = 0
            }
        }
        return false
    }
}

/// A non-activating preview card. It never takes focus from the editor and
/// does no parsing or rendering while the user is typing.
final class HoverPreviewController {
    weak var textView: EditorTextView?
    var sourceURL: URL?
    var isEnabled = true {
        didSet { if !isEnabled { hide() } }
    }
    private let renderer = SnippetRenderer()

    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
    private let imageView = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private var work: DispatchWorkItem?
    private var generation = 0
    private var lastIndex: Int?
    private var shownRange: NSRange?

    init(textView: EditorTextView) {
        self.textView = textView
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingMiddle
        background.addSubview(imageView)
        background.addSubview(caption)
        panel.contentView = background
    }

    func mouseMoved(to point: NSPoint) {
        guard isEnabled else { return }
        guard let textView, let layout = textView.layoutManager,
              let container = textView.textContainer else { hide(); return }
        let inContainer = NSPoint(x: point.x - textView.textContainerOrigin.x,
                                  y: point.y - textView.textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: inContainer, in: container)
        guard glyph < layout.numberOfGlyphs else { hide(); return }
        let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard glyphRect.contains(inContainer) else { hide(); return }
        let index = layout.characterIndexForGlyph(at: glyph)
        if let shownRange, NSLocationInRange(index, shownRange) { return }
        if lastIndex == index { return }
        hide()
        lastIndex = index
        let request = generation
        let work = DispatchWorkItem { [weak self] in self?.showPreview(at: index, generation: request) }
        self.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: work)
    }

    func hide() {
        generation += 1
        work?.cancel()
        work = nil
        renderer.cancel()
        lastIndex = nil
        shownRange = nil
        if panel.isVisible {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    private func showPreview(at index: Int, generation request: Int) {
        guard isEnabled, request == generation, let textView, let sourceURL,
              let target = HoverTarget.at(index, in: textView.string as NSString),
              let window = textView.window else { return }
        shownRange = target.range
        let layout = textView.layoutManager!
        let container = textView.textContainer!
        let anchorGlyph = layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        var anchor = layout.boundingRect(forGlyphRange: anchorGlyph, in: container)
        anchor.origin.x += textView.textContainerOrigin.x
        anchor.origin.y += textView.textContainerOrigin.y
        let screenAnchor = window.convertToScreen(textView.convert(anchor, to: nil))

        let source = textView.string as NSString
        let snippet = source.substring(with: target.range)
        presentMessage("Rendering snippet…", at: screenAnchor, parent: window)
        renderer.render(snippet: snippet, source: source as String,
                        project: sourceURL.deletingLastPathComponent()) { [weak self] image, message in
            guard let self, request == self.generation else { return }
            if let image {
                self.present(image, caption: "Rendered snippet", at: screenAnchor, parent: window)
            } else {
                self.presentMessage(message ?? "Could not render this snippet", at: screenAnchor, parent: window)
            }
        }
    }

    private func presentMessage(_ message: String, at anchor: NSRect, parent: NSWindow) {
        imageView.image = nil
        imageView.frame = .zero
        caption.stringValue = message
        caption.frame = NSRect(x: 12, y: 10, width: 276, height: 18)
        placePanel(size: NSSize(width: 300, height: 38), at: anchor, parent: parent)
    }

    private func present(_ image: CGImage, caption title: String, at anchor: NSRect, parent: NSWindow) {
        let size = NSSize(width: CGFloat(image.width), height: CGFloat(image.height))
        imageView.image = NSImage(cgImage: image, size: size)
        caption.stringValue = title
        let width = max(220, size.width + 24)
        let height = size.height + 44
        imageView.frame = NSRect(x: 12, y: 32, width: width - 24, height: size.height)
        caption.frame = NSRect(x: 12, y: 8, width: width - 24, height: 16)
        placePanel(size: NSSize(width: width, height: height), at: anchor, parent: parent)
    }

    private func placePanel(size: NSSize, at anchor: NSRect, parent: NSWindow) {
        let width = size.width, height = size.height
        var frame = NSRect(x: anchor.maxX + 14, y: anchor.midY - height / 2, width: width, height: height)
        if let visible = parent.screen?.visibleFrame {
            if frame.maxX > visible.maxX { frame.origin.x = anchor.minX - width - 14 }
            frame.origin.x = max(visible.minX + 8, min(frame.origin.x, visible.maxX - width - 8))
            frame.origin.y = max(visible.minY + 8, min(frame.origin.y, visible.maxY - height - 8))
        }
        panel.setFrame(frame, display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

}
