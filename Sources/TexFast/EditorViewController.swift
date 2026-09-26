import AppKit

/// Text view that gives the completion popup first refusal on navigation keys.
final class EditorTextView: NSTextView {
    weak var completion: CompletionController?
    var onCommandClick: ((Int, Int) -> Void)?   // line, column (1-based)
    var onHoverMove: ((NSPoint) -> Void)?
    var onHoverExit: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        onHoverMove?(convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverExit?()
        super.mouseExited(with: event)
    }

    override func keyDown(with event: NSEvent) {
        onHoverExit?()
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
        onHoverExit?()
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
    private var lineNumbers: LineNumberGutter!
    private let highlighter = LaTeXHighlighter()
    private let completion = CompletionController()
    private var hoverPreview: HoverPreviewController!

    private var highlightScheduled = false
    /// Skip redundant passes: scrolling emits many bounds changes per gesture.
    private var lastHighlightedRange = NSRange(location: NSNotFound, length: 0)
    private var diagnosticRanges: [NSRange] = []
    private var syncWork: DispatchWorkItem?
    private var completionRequestID = 0
    private var pendingTypedText: String?
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
    var autoCompileDelay: TimeInterval = 0.6

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
        hoverPreview = HoverPreviewController(textView: textView)
        hoverPreview.isEnabled = HoverPreviewPreference.isEnabled
        textView.onHoverMove = { [weak self] point in self?.hoverPreview.mouseMoved(to: point) }
        textView.onHoverExit = { [weak self] in self?.hoverPreview.hide() }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasVerticalRuler = false
        scrollView.autohidesScrollers = true
        lineNumbers = LineNumberGutter(textView: textView, scrollView: scrollView)
        let root = NSView()
        for item in [lineNumbers!, scrollView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        NSLayoutConstraint.activate([
            lineNumbers.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            lineNumbers.topAnchor.constraint(equalTo: root.topAnchor),
            lineNumbers.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            lineNumbers.widthAnchor.constraint(equalToConstant: 48),
            scrollView.leadingAnchor.constraint(equalTo: lineNumbers.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root

        completion.onCommit = { [weak self] item in self?.insert(item) }
        matchWidthToPane()

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scheduleHighlight),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLineNumbers),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(requestCompletion),
                                               name: .texFastRequestCompletion, object: textView)
        NotificationCenter.default.addObserver(self, selector: #selector(hideHoverPreview),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshHoverPreviewPreference),
                                               name: .texFastHoverPreviewsChanged, object: nil)
    }

    @objc private func hideHoverPreview() { hoverPreview.hide() }
    @objc private func refreshHoverPreviewPreference() {
        hoverPreview.isEnabled = HoverPreviewPreference.isEnabled
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        matchWidthToPane()
        lineNumbers.needsDisplay = true
    }

    @objc private func refreshLineNumbers() { lineNumbers.needsDisplay = true }

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
        let text = try String(contentsOf: url, encoding: .utf8)
        fileURL = url
        hoverPreview.sourceURL = url
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        scrollView.contentView.scroll(to: .zero)
        lineNumbers.sourceDidChange()
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
    @discardableResult
    func save() -> Bool {
        guard let fileURL else { return false }
        autoSaveWork?.cancel()
        do {
            try textView.string.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch { return false }
        isDirty = false
        lastWrittenModification = diskModification()
        lsp?.didSave(fileURL)
        onSave?()
        return true
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
        hoverPreview.hide()
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
        lineNumbers.sourceDidChange()
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

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        if !isEditingProgrammatically { pendingTypedText = replacementString }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !isEditingProgrammatically else { return }
        let typedText = pendingTypedText
        pendingTypedText = nil
        isEditingProgrammatically = true
        if typedText == "}" { autoCloseEnvironment() }
        if typedText == "\n" { autoContinueListItem() }
        isEditingProgrammatically = false

        documentWasEdited(offerCompletion: !(typedText?.isEmpty ?? true))
    }

    private func documentWasEdited(offerCompletion: Bool) {
        hoverPreview.hide()
        lastHighlightedRange = NSRange(location: NSNotFound, length: 0)
        scheduleHighlight()
        lineNumbers.sourceDidChange()

        let text = textView.string
        isDirty = true
        onTextChanged?(text)
        scheduleAutoSave()

        syncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let url = fileURL else { return }
            lsp?.didChange(url, text: self.textView.string)
            if offerCompletion && shouldOfferCompletion() { requestCompletion() }
        }
        syncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)

        if !offerCompletion || !shouldOfferCompletion() {
            completionRequestID += 1
            completion.hide()
        }
    }

    /// Offer suggestions while a command is being typed, or inside the braces of
    /// a reference-like command where texlab knows the candidate labels.
    private func shouldOfferCompletion() -> Bool {
        let ns = textView.string as NSString
        let caret = textView.selectedRange().location
        guard caret > 0 else { return false }
        let lineStart = ns.lineRange(for: NSRange(location: caret, length: 0)).location
        let prefix = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        // A percent sign after an even number of backslashes starts a comment.
        var escaped = false
        for character in prefix {
            if character == "%" && !escaped { return false }
            if character == "\\" { escaped.toggle() } else { escaped = false }
        }
        if prefix.range(of: #"\\[A-Za-z@]*$"#, options: .regularExpression) != nil { return true }
        guard let brace = prefix.lastIndex(of: "{") else { return false }
        let argument = prefix[prefix.index(after: brace)...]
        guard !argument.contains("}"), !argument.contains("\\") else { return false }
        let head = String(prefix[..<brace])
        let commands = ["ref", "eqref", "autoref", "pageref", "cref", "Cref", "cite", "citet",
                        "citep", "textcite", "parencite", "nocite", "includegraphics", "input",
                        "include", "subfile", "usepackage", "documentclass", "begin", "end",
                        "label", "bibliography", "addbibresource", "gls", "Gls"]
        return commands.contains { command in
            head.range(of: #"\\"# + command + #"\*?(\[[^\]]*\])?$"#,
                       options: .regularExpression) != nil
        }
    }

    @objc func requestCompletion() {
        guard let url = fileURL, let window = view.window else { return }
        let position = caretLineAndColumn()
        let caretLocation = textView.selectedRange().location
        let localItem = itemCompletion()
        completionRequestID += 1
        let requestID = completionRequestID
        guard let lsp, lsp.isRunning else {
            showCompletion(localItem.map { [$0] } ?? [], in: window)
            return
        }
        lsp.completion(url, line: position.line - 1, character: position.column - 1) { [weak self] items in
            guard let self else { return }
            guard requestID == completionRequestID,
                  caretLocation == textView.selectedRange().location else { return }
            let suggestions = localItem.map { item in
                [item] + items.filter { $0.label != item.label }
            } ?? items
            showCompletion(Array(suggestions.prefix(200)), in: window)
        }
    }

    private func showCompletion(_ items: [CompletionItem], in window: NSWindow) {
        guard !items.isEmpty else { completion.hide(); return }
        let rect = textView.firstRect(forCharacterRange: textView.selectedRange(), actualRange: nil)
        completion.show(items, at: NSPoint(x: rect.minX, y: rect.minY), parent: window)
    }

    private func itemCompletion() -> CompletionItem? {
        let ns = textView.string as NSString
        let caret = textView.selectedRange().location
        let lineStart = ns.lineRange(for: NSRange(location: caret, length: 0)).location
        let line = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        guard let slash = line.range(of: #"\\[A-Za-z]*$"#, options: .regularExpression),
              String(line[..<slash.lowerBound]).trimmingCharacters(in: .whitespaces).isEmpty,
              "\\item".hasPrefix(line[slash]),
              activeListKind(before: caret, in: ns) != nil else { return nil }
        return CompletionItem(label: "\\item", detail: "List item", insertText: "\\item ",
                              kindRank: 0, edit: nil)
    }

    private func insert(_ item: CompletionItem) {
        completion.hide()
        isEditingProgrammatically = true
        let ns = textView.string as NSString
        let caret = textView.selectedRange().location
        var replace: NSRange?
        if let edit = item.edit,
           let start = offset(line: edit.startLine, character: edit.startCharacter, in: ns),
           let end = offset(line: edit.endLine, character: edit.endCharacter, in: ns),
           start <= caret, caret <= end, end >= start {
            replace = NSRange(location: start, length: end - start)
        }
        if replace == nil {
            var start = caret
            while start > 0 {
                let c = ns.character(at: start - 1)
                if (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c)
                    || c == 95 || c == 45 || c == 58 || c == 46 || c == 47 { start -= 1; continue }
                if c == 92 && item.insertText.hasPrefix("\\") { start -= 1 }
                break
            }
            replace = NSRange(location: start, length: caret - start)
        }
        guard let replace else { isEditingProgrammatically = false; return }
        if textView.shouldChangeText(in: replace, replacementString: item.insertText) {
            textView.textStorage?.replaceCharacters(in: replace, with: item.insertText)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: replace.location + (item.insertText as NSString).length, length: 0))
            autoCloseEnvironment()
            isEditingProgrammatically = false
            documentWasEdited(offerCompletion: false)
        } else {
            isEditingProgrammatically = false
        }
    }

    private func offset(line: Int, character: Int, in text: NSString) -> Int? {
        guard line >= 0, character >= 0 else { return nil }
        var current = 0
        var result: Int?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                 options: [.byLines, .substringNotRequired]) { _, range, _, stop in
            if current == line {
                result = range.location + min(character, range.length)
                stop.pointee = true
            }
            current += 1
        }
        return result
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
        let isList = name == "itemize" || name == "enumerate"
        let innerIndent = isList ? indent + "    " : indent
        let firstItem = isList ? "\\item " : ""
        let insertion = "\n\(innerIndent)\(firstItem)\n\(indent)\\end{\(name)}"
        let at = NSRange(location: caret, length: 0)
        if textView.shouldChangeText(in: at, replacementString: insertion) {
            textView.textStorage?.replaceCharacters(in: at, with: insertion)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: caret + 1 + (innerIndent as NSString).length
                                              + (firstItem as NSString).length, length: 0))
        }
    }

    /// Return inside a list starts another item at the same indentation. This
    /// also handles a list whose closing tag was already present in the file.
    private func autoContinueListItem() {
        let ns = textView.string as NSString
        let caret = textView.selectedRange().location
        guard caret >= 2, caret <= ns.length, ns.character(at: caret - 1) == 10 else { return }
        let previous = ns.lineRange(for: NSRange(location: caret - 2, length: 0))
        let line = ns.substring(with: NSRange(location: previous.location,
                                              length: caret - 1 - previous.location))
        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let content = String(line.dropFirst(indent.count))
        let openingList = content == "\\begin{itemize}" || content == "\\begin{enumerate}"
        let itemLine = content.hasPrefix("\\item") &&
            (content.count == 5 || content.dropFirst(5).first.map { $0.isWhitespace || $0 == "[" } == true)
        guard openingList || itemLine,
              activeListKind(before: caret, in: ns) != nil else { return }

        let insertion = (openingList ? indent + "    " : indent) + "\\item "
        let at = NSRange(location: caret, length: 0)
        if textView.shouldChangeText(in: at, replacementString: insertion) {
            textView.textStorage?.replaceCharacters(in: at, with: insertion)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: caret + (insertion as NSString).length, length: 0))
        }
    }

    private static let listEnvironmentPattern = try! NSRegularExpression(
        pattern: #"\\(begin|end)\{(itemize|enumerate)\}"#)

    private func activeListKind(before offset: Int, in text: NSString) -> String? {
        guard offset > 0 else { return nil }
        let prefix = text.substring(to: min(offset, text.length))
        let ns = prefix as NSString
        var stack: [String] = []
        for match in Self.listEnvironmentPattern.matches(in: prefix,
                                                          range: NSRange(location: 0, length: ns.length)) {
            let lineStart = ns.lineRange(for: NSRange(location: match.range.location, length: 0)).location
            let before = ns.substring(with: NSRange(location: lineStart,
                                                     length: match.range.location - lineStart))
            var escaped = false
            var commented = false
            for character in before {
                if character == "%" && !escaped { commented = true; break }
                if character == "\\" { escaped.toggle() } else { escaped = false }
            }
            if commented { continue }
            let kind = ns.substring(with: match.range(at: 2))
            if ns.substring(with: match.range(at: 1)) == "begin" {
                stack.append(kind)
            } else if let index = stack.lastIndex(of: kind) {
                stack.removeSubrange(index..<stack.count)
            }
        }
        return stack.last
    }
}
