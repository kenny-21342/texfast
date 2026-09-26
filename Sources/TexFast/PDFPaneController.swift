import AppKit
import PDFKit

/// Right-hand preview. Reloading must never throw away the reader's place, so
/// the visible page and scroll offset are captured and restored around a reload.
final class PDFPaneController: NSViewController {

    let pdfView = PDFView()
    private var url: URL?
    /// Clicking a PDF page asks the editor to jump to the matching source line.
    var onReverseSync: ((SourceLocation) -> Void)?
    var onPageChanged: ((Int, Int) -> Void)?
    private var pageObserver: NSObjectProtocol?
    private var clickMonitor: Any?

    deinit {
        if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    }

    override func loadView() {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .underPageBackgroundColor
        view = pdfView

        // PDFKit's internal page view handles mouse clicks before a recognizer
        // attached to PDFView can see them. A local monitor observes the click
        // without consuming it, so text selection and links still work.
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

    func load(_ url: URL) {
        self.url = url
        reload()
    }

    func reload() {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }

        let previousPage = pdfView.currentPage.map { pdfView.document?.index(for: $0) ?? 0 }
        let previousOrigin = pdfView.documentView?.enclosingScrollView?.contentView.bounds.origin

        guard let document = PDFDocument(url: url) else { return }
        pdfView.document = document

        if let previousPage, previousPage < document.pageCount, let page = document.page(at: previousPage) {
            pdfView.go(to: page)
            if let previousOrigin, let clip = pdfView.documentView?.enclosingScrollView?.contentView {
                clip.scroll(to: previousOrigin)
                clip.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
        reportPage()
    }

    /// Scroll to a SyncTeX hit and flash it, so the eye lands in the right place.
    func reveal(_ location: PDFLocation) {
        guard let document = pdfView.document,
              location.page >= 1, location.page <= document.pageCount,
              let page = document.page(at: location.page - 1) else { return }

        let bounds = page.bounds(for: .mediaBox)
        // SyncTeX measures from the top-left; PDF user space from the bottom-left.
        let rect = NSRect(x: location.x - 4,
                          y: bounds.height - location.y - location.height - 4,
                          width: max(location.width, 24) + 8,
                          height: max(location.height, 12) + 8)

        pdfView.go(to: rect, on: page)
        reportPage()
        flash(rect, on: page)
    }

    private func reportPage() {
        guard let document = pdfView.document else {
            onPageChanged?(0, 0)
            return
        }
        let page = pdfView.currentPage.map { document.index(for: $0) + 1 } ?? 1
        onPageChanged?(page, document.pageCount)
    }

    private func flash(_ rect: NSRect, on page: PDFPage) {
        let highlight = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
        highlight.color = NSColor.systemYellow.withAlphaComponent(0.55)
        page.addAnnotation(highlight)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak page] in
            page?.removeAnnotation(highlight)
        }
    }

    private func handleClick(at point: NSPoint) {
        guard let url else { return }
        guard let page = pdfView.page(for: point, nearest: false),
              let document = pdfView.document else { return }
        let pageIndex = document.index(for: page)
        let onPage = pdfView.convert(point, to: page)
        let bounds = page.bounds(for: .mediaBox)

        let x = onPage.x
        let y = bounds.height - onPage.y      // back to SyncTeX's top-left origin
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let location = SyncTeX.inverse(page: pageIndex + 1, x: Double(x), y: Double(y), pdf: url) else { return }
            DispatchQueue.main.async { self?.onReverseSync?(location) }
        }
    }
}
