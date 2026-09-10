import AppKit

/// Text view that gives the completion popup first refusal on navigation keys.
final class EditorTextView: NSTextView {
    weak var completion: CompletionController?
    var onCommandClick: ((Int, Int) -> Void)?   // line, column (1-based)

    override func keyDown(with event: NSEvent) {
        if let completion, completion.isVisible {
            switch event.keyCode {
            case 125: completion.move(by: 1); return       // down
            case 126: completion.move(by: -1); return      // up
            case 36, 48:                                    // return, tab
                completion.commitSelection(); return
            case 53: completion.hide(); return              // escape
            default: break
            }
        }
        // ⌃Space asks for suggestions explicitly.
        if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == " " {
            NotificationCenter.default.post(name: .texFastRequestCompletion, object: self)
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let ns = string as NSString
        var line = 1
        var lineStart = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: index), options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
            line += 1
            lineStart = NSMaxRange(enclosing)
        }
        onCommandClick?(line, index - lineStart + 1)
    }
}

extension Notification.Name {
    static let texFastRequestCompletion = Notification.Name("texFastRequestCompletion")
}

final class EditorViewController: NSViewController, NSTextViewDelegate {

    private(set) var textView: EditorTextView!
    private let scrollView = NSScrollView()
    private let highlighter = LaTeXHighlighter()
    private let completion = CompletionController()

    private var highlightScheduled = false
    /// Skip redundant passes: scrolling emits many bounds changes per gesture.
    private var lastHighlightedRange = NSRange(location: NSNotFound, length: 0)
    private var diagnosticRanges: [NSRange] = []
    private var syncWork: DispatchWorkItem?
    /// `autoCloseEnvironment` edits the text from inside the change callback,
    /// which would otherwise re-enter this handler.
    private var isEditingProgrammatically = false

    var lsp: LSPClient?
    var fileURL: URL?
    var onSave: (() -> Void)?
    /// Raised when an auto-save is skipped because the file changed underneath us.
    var onAutoSaveBlocked: (() -> Void)?

    /// Save and compile on their own once typing pauses, with no keystroke.
    var autoCompile = true {
        didSet { if !autoCompile { autoSaveWork?.cancel() } }
    }
    var autoCompileDelay: TimeInterval = 1.2

    private var autoSaveWork: DispatchWorkItem?
    private var isDirty = false
    /// Modification date as of our own last write, used to notice edits made in
    /// another editor rather than silently overwriting them.
    private var lastWrittenModification: Date?
    var onForwardSync: ((Int, Int) -> Void)?
    var onTextChanged: ((String) -> Void)?

    override func loadView() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        // Non-contiguous layout sounds right for a 9,000-line file, but it lays
        // out lazily and *estimates* the rest: the scroller thumb jumps as
        // estimates are refined, and dragging it to an arbitrary point forces a
        // large synchronous layout. With uniform monospaced metrics the whole
        // document lays out once in well under a second, after which scrolling
        // is exact and instant.
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)
        let startingSize = NSSize(width: 600, height: 600)
        let container = NSTextContainer(size: NSSize(width: startingSize.width,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        textView = EditorTextView(frame: NSRect(origin: .zero, size: startingSize),
                                  textContainer: container)
        textView.delegate = self
        textView.completion = completion
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // A hand-built NSTextView grows only up to maxSize, which otherwise
        // defaults to its initial frame — leaving the document stuck at one
        // screenful with nothing to scroll.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.onCommandClick = { [weak self] line, column in self?.onForwardSync?(line, column) }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasVerticalRuler = false
        scrollView.autohidesScrollers = true
        view = scrollView

        completion.onCommit = { [weak self] item in self?.insert(item) }
        matchWidthToPane()

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleHighlight),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(requestCompletion),
                                               name: .texFastRequestCompletion, object: nil)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        matchWidthToPane()
    }

    /// Keep the text and its container exactly as wide as the visible pane, so
    /// long lines wrap instead of running off the right edge unreachably.
    private func matchWidthToPane() {
        guard let container = textView?.textContainer else { return }
        let width = scrollView.contentSize.width
        guard width > 0 else { return }
        if abs(container.containerSize.width - width) > 0.5 {
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        }
        if abs(textView.frame.width - width) > 0.5 {
            textView.frame.size.width = width
        }
        lastHighlightedRange = NSRange(location: NSNotFound, length: 0)
    }

    // MARK: - document

    func load(_ url: URL) throws {
        fileURL = url
        let text = try String(contentsOf: url, encoding: .utf8)
        textView.string = text
        // Lay the whole document out now, so the scroller is accurate from the
        // first frame rather than settling as you scroll.
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
        }
        lastHighlightedRange = NSRange(location: NSNotFound, length: 0)
        diagnosticRanges = []
        isDirty = false
        lastWrittenModification = diskModification()
        scheduleHighlight()
        lsp?.didOpen(url, text: text)
    }

    /// Explicit save. Always writes, even over an external change — the user asked.
    func save() {
        guard let fileURL else { return }
        autoSaveWork?.cancel()
        try? textView.string.write(to: fileURL, atomically: true, encoding: .utf8)
        isDirty = false
        lastWrittenModification = diskModification()
        lsp?.didSave(fileURL)
        onSave?()
    }

    /// True when the file on disk is newer than our own last write to it.
    var fileChangedOnDisk: Bool {
        guard let disk = diskModification() else { return false }
        guard let mine = lastWrittenModification else { return true }
        return disk > mine
    }

    var hasUnsavedChanges: Bool { isDirty }

    /// Take the version on disk, keeping the caret and scroll position. Used
    /// when another process — a coding agent, another editor — rewrites the file.
    @discardableResult
    func reloadFromDisk() -> Bool {
        guard let fileURL, let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        if text == textView.string {
            lastWrittenModification = diskModification()
            return false
        }

        let selection = textView.selectedRange()
        let offset = scrollView.contentView.bounds.origin

        autoSaveWork?.cancel()
        isEditingProgrammatically = true
        textView.string = text
        isEditingProgrammatically = false

        // Lay out before restoring the offset, or it clamps against a stale height.
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
        }
        let length = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        scrollView.contentView.scroll(to: offset)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        isDirty = false
        lastWrittenModification = diskModification()
        lastHighlightedRange = NSRange(location: NSNotFound, length: 0)
        diagnosticRanges = []
        scheduleHighlight()
        lsp?.didChange(fileURL, text: text)
        return true
    }

    /// Save triggered by the idle timer rather than by the user.
    private func autoSave() {
        guard autoCompile, isDirty, fileURL != nil else { return }
        // Never let a background timer clobber an edit made elsewhere.
        if let disk = diskModification(), let mine = lastWrittenModification, disk > mine {
            onAutoSaveBlocked?()
            return
        }
        save()
    }

    private func scheduleAutoSave() {
        autoSaveWork?.cancel()
        guard autoCompile else { return }
        let work = DispatchWorkItem { [weak self] in self?.autoSave() }
        autoSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoCompileDelay, execute: work)
    }

    private func diskModification() -> Date? {
        guard let fileURL else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    func jump(toLine line: Int) {
        let ns = textView.string as NSString
        var current = 1
        var location = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byLines, .substringNotRequired]) { _, range, _, stop in
            if current == line { location = range.location; stop.pointee = true }
            current += 1
        }
        let target = NSRange(location: min(location, ns.length), length: 0)
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        textView.showFindIndicator(for: ns.lineRange(for: target))
    }

    func caretLineAndColumn() -> (line: Int, column: Int) {
        let index = textView.selectedRange().location
        let ns = textView.string as NSString
        var line = 1, lineStart = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: index),
                               options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
            line += 1
            lineStart = NSMaxRange(enclosing)
        }
        return (line, index - lineStart + 1)
    }

    // MARK: - highlighting

    @objc private func scheduleHighlight() {
        guard !highlightScheduled else { return }
        highlightScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            highlightScheduled = false
            applyHighlight()
        }
    }

    private func applyHighlight() {
        guard let storage = textView.textStorage,
              let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        let visibleRect = scrollView.contentView.bounds
        let glyphRange = layout.glyphRange(forBoundingRect: visibleRect, in: container)
        let charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        // A single scroll gesture fires many bounds changes; only redo the work
        // once the visible range has actually moved.
        if NSEqualRanges(charRange, lastHighlightedRange) { return }
        lastHighlightedRange = charRange

        highlighter.highlight(storage, layout: layout, visible: charRange)
    }

    // MARK: - diagnostics

    /// Underline problem lines. Like highlighting, this uses temporary
    /// attributes — the previous version cleared attributes across the whole
    /// document, which invalidated layout for all 9,000 lines on every
    /// diagnostics update and froze the UI.
    func apply(_ diagnostics: [Diagnostic]) {
        guard let layout = textView.layoutManager else { return }
        let ns = textView.string as NSString

        for range in diagnosticRanges where NSMaxRange(range) <= ns.length {
            layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
            layout.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
        }
        diagnosticRanges = []

        // Line lookup is O(n) per diagnostic, so resolve them in one walk.
        let wanted = Set(diagnostics.map(\.line))
        var lineStarts: [Int: NSRange] = [:]
        var current = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byLines, .substringNotRequired]) { _, range, _, stop in
            if wanted.contains(current) { lineStarts[current] = range }
            current += 1
            if lineStarts.count == wanted.count { stop.pointee = true }
        }

        for d in diagnostics {
            guard let range = lineStarts[d.line] else { continue }
            layout.setTemporaryAttributes([
                .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                .underlineColor: d.severity == 1 ? NSColor.systemRed : NSColor.systemOrange
            ], forCharacterRange: range)
            diagnosticRanges.append(range)
        }
    }

    // MARK: - completion

    func textDidChange(_ notification: Notification) {
        guard !isEditingProgrammatically else { return }
        lastHighlightedRange = NSRange(location: NSNotFound, length: 0)
        scheduleHighlight()
        isEditingProgrammatically = true
        autoCloseEnvironment()
        isEditingProgrammatically = false

        let text = textView.string
        isDirty = true
        onTextChanged?(text)
        scheduleAutoSave()

        syncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let url = fileURL else { return }
            lsp?.didChange(url, text: self.textView.string)
        }
        syncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)

        if shouldOfferCompletion() { requestCompletion() } else { completion.hide() }
    }

    /// Offer suggestions while a command is being typed, or inside the braces of
    /// a reference-like command where texlab knows the candidate labels.
    private func shouldOfferCompletion() -> Bool {
        let ns = textView.string as NSString
        let caret = textView.selectedRange().location
        guard caret > 0 else { return false }
        let start = max(0, caret - 40)
        let prefix = ns.substring(with: NSRange(location: start, length: caret - start))
        if let slash = prefix.lastIndex(of: "\\") {
            let after = prefix[prefix.index(after: slash)...]
            if after.allSatisfy({ $0.isLetter }) { return true }
        }
        if let brace = prefix.lastIndex(of: "{") {
            let head = prefix[..<brace]
            for command in ["\\ref", "\\eqref", "\\cite", "\\includegraphics", "\\input", "\\include", "\\usepackage", "\\begin", "\\end"]
            where head.hasSuffix(command) {
                return !prefix[prefix.index(after: brace)...].contains("}")
            }
        }
        return false
    }

    @objc func requestCompletion() {
        guard let lsp, lsp.isRunning, let url = fileURL, let window = view.window else { return }
        let position = caretLineAndColumn()
        lsp.completion(url, line: position.line - 1, character: position.column - 1) { [weak self] items in
            guard let self else { return }
            guard !items.isEmpty else { completion.hide(); return }
            let caret = textView.selectedRange()
            let rectInView = textView.firstRect(forCharacterRange: caret, actualRange: nil)
            let point = NSPoint(x: rectInView.minX, y: rectInView.minY)
            completion.show(Array(items.prefix(200)), at: point, parent: window)
        }
    }

    private func insert(_ item: CompletionItem) {
        completion.hide()
        isEditingProgrammatically = true
        defer { isEditingProgrammatically = false }
        let ns = textView.string as NSString
        let caret = textView.selectedRange().location
        // Replace whatever fragment of the token has already been typed.
        var start = caret
        while start > 0 {
            let c = ns.character(at: start - 1)
            let scalar = Character(UnicodeScalar(c) ?? " ")
            if scalar.isLetter { start -= 1; continue }
            if scalar == "\\" { start -= 1 }
            break
        }
        let replace = NSRange(location: start, length: caret - start)
        if textView.shouldChangeText(in: replace, replacementString: item.insertText) {
            textView.textStorage?.replaceCharacters(in: replace, with: item.insertText)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: start + (item.insertText as NSString).length, length: 0))
        }
    }

    /// Typing the closing brace of `\begin{foo}` writes the matching `\end{foo}`.
    private func autoCloseEnvironment() {
        let ns = textView.string as NSString
        let caret = textView.selectedRange().location
        guard caret > 0, caret <= ns.length, ns.character(at: caret - 1) == 125 else { return } // }
        let lineStart = ns.lineRange(for: NSRange(location: caret - 1, length: 0)).location
        let head = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        guard let open = head.range(of: "\\begin{", options: .backwards) else { return }
        let name = String(head[open.upperBound...].dropLast())
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0 == "*" }) else { return }
        // Do not duplicate a closing tag the user already has.
        let ahead = ns.substring(from: caret)
        if ahead.prefix(400).contains("\\end{\(name)}") { return }

        let indent = String(head.prefix(while: { $0 == " " || $0 == "\t" }))
        let insertion = "\n\(indent)\n\(indent)\\end{\(name)}"
        let at = NSRange(location: caret, length: 0)
        if textView.shouldChangeText(in: at, replacementString: insertion) {
            textView.textStorage?.replaceCharacters(in: at, with: insertion)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: caret + 1 + (indent as NSString).length, length: 0))
        }
    }
}
