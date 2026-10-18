import AppKit
import TexFastCore

@main struct UpdateUISmoke {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("engine-update-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = EngineStore(root: folder)
        guard let actual = EnginePackage.bundled() else { fatalError("Bundle has no engine") }
        // Simulate a previous app release to exercise the real Install button.
        // All downloads and selection writes stay in this disposable store.
        let previous = EnginePackage(binary: actual.binary, tex: actual.tex, version: "v0.0.10")
        let controller = EngineUpdateWindowController(bundled: previous, running: previous, store: store)
        controller.showAndCheck()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                if condition() { return }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            let text = descendants(controller.window!.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
            fatalError("Engine update UI timed out: \(text)")
        }
        let views = descendants(controller.window!.contentView!)
        var install: NSButton?
        wait {
            install = views.compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("Install v") && $0.isEnabled }
            return install != nil
        }
        install!.performClick(nil)
        wait {
            store.selected(compatibleWith: actual.version) != nil && install!.isEnabled &&
                views.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("is ready") }
        }
        guard let package = store.selected(compatibleWith: actual.version),
              views.compactMap({ $0 as? NSTextField }).contains(where: {
                  $0.stringValue.contains("Running: v0.0.10") && $0.stringValue.contains("After restart: \(package.version)")
              }) else { fatalError("Update did not retain the running engine and show the pending version") }
        let result = Shell.run(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/rtex-host").path,
                               ["--version"], cwd: folder,
                               env: ["RTEX_ENGINE_BINARY": package.binary.path, "RTEX_TEXDIR": package.tex.path])
        guard result.status == 0, result.output.contains(String(package.version.dropFirst())) else {
            fatalError("Could not launch selected engine: \(result.output)")
        }
        try store.useBundled()
        guard !store.hasSelection, FileManager.default.isExecutableFile(atPath: package.binary.path) else {
            fatalError("Rollback removed files in use")
        }
        controller.close()
        print("PASS: native update window, real GitHub check and Install button, verified package, restart status, supervised engine launch, isolated rollback")
    }
}
