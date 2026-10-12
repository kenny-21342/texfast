import AppKit
import PDFKit

/// PDFKit manages scale, scrolling and rotation; the overlay only paints edited units.
final class NativeLiveOverlay: NSObject, PDFPageOverlayViewProvider {
    private var document: PDFDocument?
    private var revisionFloor = 0
    private var units: [Int: NativeLiveUnit] = [:]
    private var views: [ObjectIdentifier: NativeLiveOverlayView] = [:]
    var onPaint: ((Int, Int, UInt64) -> Void)?

    func install(document: PDFDocument, revision: Int) {
        self.document = document
        revisionFloor = revision
        units = units.filter { $0.value.revision > revision }
        views.removeAll()
    }
    func apply(_ unit: NativeLiveUnit) {
        guard unit.revision > revisionFloor, unit.revision >= (units[unit.id]?.revision ?? 0) else { return }
        units[unit.id] = unit
        for view in views.values {
            let old = view.units[unit.id]?.bounds ?? .null
            if let page = unit.pages[view.pageNumber] { view.units[unit.id] = page }
            else { view.units.removeValue(forKey: unit.id) }
            view.revisions[unit.id] = unit.revision
            view.invalidate(old.union(unit.pages[view.pageNumber]?.bounds ?? .null))
            // Paint a visible page immediately, without another debounce or timer.
            if view.window != nil && !view.visibleRect.isEmpty { view.displayIfNeeded() }
        }
    }
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        guard let document else { return nil }
        let key = ObjectIdentifier(page)
        if let existing = views[key] { return existing }
        let n = document.index(for: page) + 1
        let overlay = NativeLiveOverlayView(pageNumber: n, size: page.bounds(for: .mediaBox).size)
        for unit in units.values {
            if let drawing = unit.pages[n] { overlay.units[unit.id] = drawing; overlay.revisions[unit.id] = unit.revision }
        }
        overlay.onPaint = { [weak self] id, revision, time in self?.onPaint?(id, revision, time) }
        views[key] = overlay
        return overlay
    }
    /// Used by the visual fidelity test to capture the same operations the live view draws.
    func draw(page: Int, in context: CGContext) {
        let drawings = units.values.compactMap { $0.pages[page] }
        drawLivePages(drawings, in: context)
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
        drawLivePages(Array(units.values), in: context)
        context.restoreGState()
        let time = DispatchTime.now().uptimeNanoseconds
        for (id, revision) in revisions where units[id] != nil && revision > (painted[id] ?? 0) {
            painted[id] = revision
            onPaint?(id, revision, time)
        }
    }
}
