import Foundation
import TexFastCore

/// Serialises builds and keeps the UI informed. Builds run off the main queue;
/// a build requested while one is in flight is coalesced into a single rerun.
final class BuildController {
    enum State { case idle, warming, building }

    private let driver: Driver
    private let queue = DispatchQueue(label: "texfast.build")
    private var running = false
    private var pendingRebuild = false

    var onState: ((State, String) -> Void)?
    var onFinished: ((BuildReport?) -> Void)?

    init(driver: Driver) { self.driver = driver }

    var pdfURL: URL { driver.draftPDF }
    var shadowURL: URL { driver.shadowFile }

    /// True before the figure cache exists, when the first build is minutes, not seconds.
    var needsWarmUp: Bool {
        !FileManager.default.fileExists(atPath: driver.buildDir.appendingPathComponent("figs").path)
    }

    func warmUp() {
        report(.warming, "Building figure cache — this happens once")
        queue.async { [self] in
            let r = driver.build(figuresOnly: true)
            DispatchQueue.main.async { [self] in
                report(.idle, "Cached \(r.figuresBuilt) figure(s)")
                onFinished?(r)
            }
        }
    }

    func build() {
        if running { pendingRebuild = true; return }
        running = true
        report(.building, "Compiling…")
        queue.async { [self] in
            let r = driver.build(figuresOnly: false)
            DispatchQueue.main.async { [self] in
                running = false
                let summary = r.error ?? String(format: "%.1fs · %d figure(s) cached", r.totalSeconds, r.figuresCached)
                report(.idle, summary)
                onFinished?(r)
                if pendingRebuild { pendingRebuild = false; build() }
            }
        }
    }

    private func report(_ state: State, _ message: String) {
        if Thread.isMainThread { onState?(state, message) }
        else { DispatchQueue.main.async { [weak self] in self?.onState?(state, message) } }
    }
}
