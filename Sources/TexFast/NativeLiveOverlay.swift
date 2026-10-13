import AppKit
import PDFKit

/// PDFKit manages scale, scrolling and rotation; the overlay only paints edited units.
final class NativeLiveOverlay: NSObject, PDFPageOverlayViewProvider {
    private var document: PDFDocument?
    private var revisionFloor = 0
    private var units: [Int: NativeLiveUnit] = [:]
    private var previews: [Int: NativeLivePagePreview] = [:]
    private var views: [ObjectIdentifier: NativeLiveOverlayView] = [:]
    var onPreviewPaint: ((Int, Int, UInt64) -> Void)?
    var onPaint: ((Int, Int, UInt64) -> Void)?

    func install(document: PDFDocument, revision: Int) {
        self.document = document
        revisionFloor = revision
        previews.removeAll()
        units = units.filter { $0.value.revision > revision }
        views.removeAll()
    }
    func clear() {
        revisionFloor = Int.max
        units.removeAll(); previews.removeAll()
        for view in views.values {
            view.units.removeAll(); view.revisions.removeAll(); view.preview = nil
            view.needsDisplay = true
        }
    }
    func apply(_ unit: NativeLiveUnit) {
        guard unit.revision > revisionFloor, unit.revision >= (units[unit.id]?.revision ?? 0) else { return }
        guard let document, unit.pages.keys.allSatisfy({ n in
            guard n > 0, n <= document.pageCount, let page = document.page(at: n - 1) else { return false }
            return supports(page)
        }) else { return }
        units[unit.id] = unit
        for view in views.values {
            let old = view.units[unit.id]?.bounds ?? .null
            if let page = visible(unit, on: view.pageNumber) { view.units[unit.id] = page }
            else { view.units.removeValue(forKey: unit.id) }
            view.revisions[unit.id] = unit.revision
            view.invalidate(old.union(unit.pages[view.pageNumber]?.bounds ?? .null))
            // Paint a visible page immediately, without another debounce or timer.
            if view.window != nil && !view.visibleRect.isEmpty { view.displayIfNeeded() }
        }
    }
    func applyPreview(_ preview: NativeLivePagePreview, units current: [NativeLiveUnit]) {
        guard preview.revision >= revisionFloor, let document,
              let page = document.page(at: preview.page - 1), supports(page),
              abs(page.bounds(for: .mediaBox).width - preview.size.width) < 0.1,
              abs(page.bounds(for: .mediaBox).height - preview.size.height) < 0.1 else { return }
        previews[preview.page] = preview
        replaceUnits(current, changedPage: preview.page)
    }

    func resetPreviews(units current: [NativeLiveUnit]) {
        previews.removeAll(); replaceUnits(current)
    }

    private func visible(_ unit: NativeLiveUnit, on page: Int) -> NativeLivePage? {
        guard unit.revision > (previews[page]?.revision ?? revisionFloor) else { return nil }
        return unit.pages[page]
    }

    private func replaceUnits(_ current: [NativeLiveUnit], changedPage: Int? = nil) {
        units = Dictionary(current.filter { $0.revision > revisionFloor }.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        for view in views.values {
            var drawings: [Int: NativeLivePage] = [:], revisions: [Int: Int] = [:]
            for unit in units.values {
                if let page = visible(unit, on: view.pageNumber) { drawings[unit.id] = page; revisions[unit.id] = unit.revision }
            }
            let changed = changedPage == nil || changedPage == view.pageNumber || revisions != view.revisions ||
                drawings.contains { id, page in page.masks != view.units[id]?.masks }
            view.units = drawings; view.revisions = revisions; view.preview = previews[view.pageNumber]
            if changed {
                if changedPage == nil || changedPage == view.pageNumber { view.previewPainted = 0 }
                view.needsDisplay = true
                if view.window != nil && !view.visibleRect.isEmpty { view.displayIfNeeded() }
            }
        }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        guard let document else { return nil }
        let key = ObjectIdentifier(page)
        if let existing = views[key] { return existing }
        let index = document.index(for: page)
        guard index != NSNotFound, supports(page) else { return nil }
        let n = index + 1
        let overlay = NativeLiveOverlayView(pageNumber: n, size: page.bounds(for: .mediaBox).size)
        for unit in units.values {
            if let drawing = visible(unit, on: n) { overlay.units[unit.id] = drawing; overlay.revisions[unit.id] = unit.revision }
        }
        overlay.preview = previews[n]
        overlay.onPreviewPaint = { [weak self] page, revision, time in self?.onPreviewPaint?(page, revision, time) }
        overlay.onPaint = { [weak self] id, revision, time in self?.onPaint?(id, revision, time) }
        views[key] = overlay
        return overlay
    }
    /// Used by the visual fidelity test to capture the same operations the live view draws.
    func draw(page: Int, in context: CGContext) {
        let drawings = units.values.compactMap { visible($0, on: page) }
        if let preview = previews[page] { drawLivePages([preview.content], in: context) }
        drawLivePages(drawings, in: context)
    }

    private func supports(_ page: PDFPage) -> Bool {
        let media = page.bounds(for: .mediaBox)
        return page.rotation == 0 && media.origin == .zero && page.bounds(for: .cropBox) == media
    }
}

private func drawLivePages(_ pages: [NativeLivePage], in context: CGContext) {
    context.saveGState()
    context.setFillColor(NSColor.white.cgColor)
    // Clear all old/new bands first, then paint all updated units so masks never erase another edit.
    for page in pages { for rect in page.masks { context.fill(rect) } }
    for page in pages {
        context.saveGState()
        for operation in page.drawing { operation.draw(in: context) }
        context.restoreGState()
    }
    context.restoreGState()
}

private final class NativeLiveOverlayView: NSView {
    let pageNumber: Int
    let pageSize: CGSize
    var units: [Int: NativeLivePage] = [:]
    var revisions: [Int: Int] = [:]
    var preview: NativeLivePagePreview?
    var previewPainted = 0
    var onPreviewPaint: ((Int, Int, UInt64) -> Void)?
    private var painted: [Int: Int] = [:]
    var onPaint: ((Int, Int, UInt64) -> Void)?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // keep PDFKit selection/navigation
    init(pageNumber: Int, size: CGSize) {
        self.pageNumber = pageNumber; pageSize = size
        super.init(frame: CGRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func invalidate(_ rect: CGRect) {
        guard !rect.isNull, pageSize.width > 0, pageSize.height > 0 else { return }
        let scale = CGAffineTransform(scaleX: bounds.width / pageSize.width, y: bounds.height / pageSize.height)
        setNeedsDisplay(rect.applying(scale).insetBy(dx: -2, dy: -2))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, pageSize.width > 0, pageSize.height > 0 else { return }
        context.saveGState()
        context.scaleBy(x: bounds.width / pageSize.width, y: bounds.height / pageSize.height)
        if let preview { drawLivePages([preview.content], in: context) }
        drawLivePages(Array(units.values), in: context)
        context.restoreGState()
        let time = DispatchTime.now().uptimeNanoseconds
        if let preview, preview.revision > previewPainted {
            previewPainted = preview.revision
            onPreviewPaint?(pageNumber, preview.revision, time)
        }
        for (id, revision) in revisions where units[id] != nil && revision > (painted[id] ?? 0) {
            painted[id] = revision
            onPaint?(id, revision, time)
        }
    }
}
