import Foundation
import PDFKit
import TexFastCore

/// Serialises builds and keeps the UI informed. Builds run off the main queue;
/// a build requested while one is in flight is coalesced into a single rerun.
final class BuildController {
    enum State { case idle, building }

    private let driver: Driver
    private let queue = DispatchQueue(label: "texfast.build")
    private var running = false
    private var pendingRebuild = false
    private var renderingFinal = false
    private var sourceRevision = 0
    private var activeRevision = -1
    private var currentCancellation: BuildCancellation?

    var onState: ((State, String) -> Void)?
    var onFinished: ((BuildReport?) -> Void)?

    init(driver: Driver) { self.driver = driver }

    var pdfURL: URL { driver.draftPDF }
    var shadowURL: URL { driver.shadowFile }
    var buildLogURL: URL { driver.buildLog }
    var isBusy: Bool { running || renderingFinal }

    func sourceDidChange() {
        sourceRevision += 1
        currentCancellation?.cancel()
    }

    /// True before the figure cache exists, when the first build is minutes, not seconds.
    var needsWarmUp: Bool {
        !FileManager.default.fileExists(atPath: driver.buildDir.appendingPathComponent("figs").path)
    }

    func build() {
        if renderingFinal { return }
        if running {
            if sourceRevision == activeRevision { return }
            pendingRebuild = true
            currentCancellation?.cancel()
            return
        }
        running = true
        let revision = sourceRevision
        activeRevision = revision
        let cancellation = BuildCancellation()
        currentCancellation = cancellation
        report(.building, needsWarmUp ? "Building figure cache…" : "Compiling…")
        queue.async { [self] in
            let r = driver.build(figuresOnly: false, previewOnly: true,
                                 cancellation: cancellation)
            DispatchQueue.main.async { [self] in
                running = false
                currentCancellation = nil
                if renderingFinal { return }
                if pendingRebuild {
                    pendingRebuild = false
                    onFinished?(nil)
                    build()
                    return
                }
                if r.cancelled {
                    report(.idle, "Preview waiting for the latest edit…")
                    onFinished?(nil)
                    return
                }
                let summary = r.error ?? String(format: "%.1fs · %d figure(s) cached", r.totalSeconds, r.figuresCached)
                report(.idle, summary)
                onFinished?(revision == sourceRevision ? r : nil)
            }
        }
    }

    /// Enqueued after any draft already in flight. The shared build lock also
    /// keeps command-line builds from touching the same intermediate files.
    func buildFinal(onPage: @escaping (Int, Int, Int) -> Void,
                    finished: @escaping (BuildReport) -> Void) {
        renderingFinal = true
        pendingRebuild = false
        currentCancellation?.cancel()
        var finalDriver = driver
        finalDriver.draft = false
        report(.building, "Rendering final PDF…")
        queue.async {
            let previousFinal = finalDriver.texFile.deletingPathExtension().appendingPathExtension("pdf")
            let totalPages = PDFDocument(url: finalDriver.draftPDF)?.pageCount
                ?? PDFDocument(url: previousFinal)?.pageCount ?? 0
            let result = finalDriver.build(figuresOnly: false) { pass, page in
                DispatchQueue.main.async { onPage(pass, page, totalPages) }
            }
            DispatchQueue.main.async {
                self.renderingFinal = false
                self.report(.idle, result.error ?? "Final PDF saved")
                finished(result)
            }
        }
    }

    private func report(_ state: State, _ message: String) {
        if Thread.isMainThread { onState?(state, message) }
        else { DispatchQueue.main.async { [weak self] in self?.onState?(state, message) } }
    }
}
