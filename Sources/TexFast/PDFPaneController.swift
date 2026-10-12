import AppKit
import PDFKit

/// Native PDFKit preview shared by the standard and realtime engines.
/// Complete PDF snapshots retain the reader's page, zoom and scroll position.
final class PDFPaneController: NSViewController {
    let pdfView = PDFView()
    let liveOverlay = NativeLiveOverlay()
    private var url: URL?
    private var previousDocuments: [PDFDocument] = []
    private var realtimeJump: ((Int, Double, Double) -> Void)?
    private var recompileAction: (() -> Void)?
    private var exportAction: (() -> Void)?
    private var toolbar: NSStackView!
    private var toolbarHeight: NSLayoutConstraint!
    var onReverseSync: ((SourceLocation) -> Void)?
    var onPageChanged: ((Int, Int) -> Void)?
    private var pageObserver: NSObjectProtocol?
    private var clickMonitor: Any?

    deinit {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    override func loadView() {
        let root = NSView()
        pdfView.pageOverlayViewProvider = liveOverlay
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .underPageBackgroundColor
        toolbar = NSStackView(views: [
            button("−", action: #selector(zoomOut(_:)), help: "Zoom out"),
            button("+", action: #selector(zoomIn(_:)), help: "Zoom in"),
            button("Fit", action: #selector(fit(_:)), help: "Fit the page to the preview"),
            button("Recompile", action: #selector(recompile(_:)), help: "Update the whole document layout"),
            button("Export PDF", action: #selector(exportPDF(_:)), help: "Save and render a clean final PDF")
        ])
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.isHidden = true
        for item in [toolbar!, pdfView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        toolbarHeight = toolbar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -8),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor), toolbarHeight,
            pdfView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            pdfView.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root

        // Observe clicks without consuming them: PDFKit selection and links still work.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === pdfView.window else { return event }
            let point = pdfView.convert(event.locationInWindow, from: nil)
            if pdfView.bounds.contains(point) { handleClick(at: point) }
            return event
        }
        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main
        ) { [weak self] _ in self?.reportPage() }
    }

    private func button(_ title: String, action: Selector, help: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.toolTip = help
        return button
    }

    func enableRealtime(recompile: @escaping () -> Void, export: @escaping () -> Void,
                        jump: @escaping (Int, Double, Double) -> Void) {
        _ = view
        recompileAction = recompile; exportAction = export; realtimeJump = jump
        toolbar.isHidden = false
        toolbarHeight.constant = 30
    }

    func disableRealtime() {
        liveOverlay.clear()
        pdfView.needsDisplay = true
        recompileAction = nil; exportAction = nil; realtimeJump = nil
        toolbar.isHidden = true
        toolbarHeight.constant = 0
    }

    func load(_ url: URL) {
        self.url = url
        reload()
    }

    func reload() {
        guard let url, let document = PDFDocument(url: url), document.pageCount > 0 else { return }
        replace(document)
    }

    /// The engine owns/prunes its files. PDFDocument(data:) retains an independent snapshot.
    @discardableResult
    func display(_ data: Data, revision: Int = Int.max) -> Bool {
        _ = view
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { return false }
        replace(document, revision: revision)
        return true
    }

    func displayFast(_ unit: NativeLiveUnit) {
        liveOverlay.apply(unit)
    }

    private func replace(_ document: PDFDocument, revision: Int = Int.max) {
        _ = view
        let previousPage = pdfView.currentPage.map { pdfView.document?.index(for: $0) ?? 0 }
        let previousOrigin = pdfView.documentView?.enclosingScrollView?.contentView.bounds.origin
        let fitting = pdfView.autoScales
        let scale = pdfView.scaleFactor
        // PDFKit can finish drawing an old page asynchronously during replacement.
        // Retain a bounded pair of snapshots so its page keeps a valid document.
        if let previous = pdfView.document {
            previousDocuments.append(previous)
            if previousDocuments.count > 2 { previousDocuments.removeFirst() }
        }
        liveOverlay.install(document: document, revision: revision)
        pdfView.document = document
        if !fitting { pdfView.scaleFactor = scale }
        if let previousPage, let page = document.page(at: min(previousPage, document.pageCount - 1)) {
            pdfView.go(to: page)
            if let previousOrigin, let clip = pdfView.documentView?.enclosingScrollView?.contentView {
                clip.scroll(to: previousOrigin)
                clip.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
        reportPage()
    }

    func reveal(_ location: PDFLocation) {
        guard let document = pdfView.document, location.page >= 1,
              location.page <= document.pageCount, let page = document.page(at: location.page - 1) else { return }
        let bounds = page.bounds(for: .mediaBox)
        let rect = NSRect(x: location.x - 4, y: bounds.height - location.y - location.height - 4,
                          width: max(location.width, 24) + 8, height: max(location.height, 12) + 8)
        pdfView.go(to: rect, on: page)
        reportPage()
        let highlight = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
        highlight.color = NSColor.systemYellow.withAlphaComponent(0.55)
        page.addAnnotation(highlight)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak page] in page?.removeAnnotation(highlight) }
    }

    private func reportPage() {
        guard let document = pdfView.document else { onPageChanged?(0, 0); return }
        let page = pdfView.currentPage.map { document.index(for: $0) + 1 } ?? 1
        onPageChanged?(page, document.pageCount)
    }

    private func handleClick(at point: NSPoint) {
        guard let page = pdfView.page(for: point, nearest: false), let document = pdfView.document else { return }
        let pageIndex = document.index(for: page)
        let onPage = pdfView.convert(point, to: page)
        let bounds = page.bounds(for: .mediaBox)
        let x = Double(onPage.x), y = Double(bounds.height - onPage.y)
        if let realtimeJump { realtimeJump(pageIndex + 1, x, y); return }
        guard let url else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let location = SyncTeX.inverse(page: pageIndex + 1, x: x, y: y, pdf: url) else { return }
            DispatchQueue.main.async { self?.onReverseSync?(location) }
        }
    }

    @objc private func zoomIn(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc private func zoomOut(_ sender: Any?) { pdfView.zoomOut(sender) }
    @objc private func fit(_ sender: Any?) { pdfView.autoScales = true }
    @objc private func recompile(_ sender: Any?) { recompileAction?() }
    @objc private func exportPDF(_ sender: Any?) { exportAction?() }
}
