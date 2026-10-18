import Foundation
import TexFastCore

@main struct Smoke {
    static func main() async throws {
        let release = try await EngineUpdates.latest()
        let asset = try release.asset(bundledVersion: "v0.0.11")
        let archive = try await EngineUpdates.download(asset)
        defer { try? FileManager.default.removeItem(at: archive) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-update-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EngineStore(root: root.appendingPathComponent("Engines"))
        let installed = try store.install(archive: archive, release: release, bundledVersion: "v0.0.11")
        guard store.selected(compatibleWith: "v0.0.11")?.binary == installed.binary else {
            throw EngineUpdateError("New engine selection was not retained")
        }
        // Start through the actual shipped process supervisor, not a copied rtex.
        // The normal CLI test then exercises edits using these downloaded files.
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let result = Shell.run(repo.appendingPathComponent("TexFast Realtime.app/Contents/MacOS/rtex-host").path,
                               ["--version"], cwd: root, env: ["RTEX_ENGINE_BINARY": installed.binary.path,
                                                            "RTEX_TEXDIR": installed.tex.path])
        guard result.status == 0, result.output.contains(String(release.tag_name.dropFirst())) else {
            throw EngineUpdateError("Supervisor could not launch downloaded engine: \(result.output)")
        }
        let live = Shell.run("/usr/bin/env", ["python3", "scripts/test-realtime-engine.py"], cwd: repo,
                             env: ["TEXFAST_TEST_ENGINE": installed.binary.path,
                                   "TEXFAST_TEST_ENGINE_TEXDIR": installed.tex.path])
        print(live.output)
        guard live.status == 0 else { throw EngineUpdateError("Downloaded engine live editing failed") }
        try store.useBundled()
        guard !store.hasSelection, FileManager.default.isExecutableFile(atPath: installed.binary.path) else {
            throw EngineUpdateError("Rollback damaged the active engine")
        }
        print("PASS: GitHub check, real download, SHA-256, matched resources, persistent selection, supervised launch, live editing and rollback (\(release.tag_name))")
    }
}
