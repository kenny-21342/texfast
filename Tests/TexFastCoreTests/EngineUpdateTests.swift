import XCTest
import CryptoKit
@testable import TexFastCore

final class EngineUpdateTests: XCTestCase {
    func testVersionOrderingAndCompatibility() {
        XCTAssertLessThan(EngineVersion("v0.0.9")!, EngineVersion("v0.0.11")!)
        XCTAssertEqual(EngineVersion("0.0.11"), EngineVersion("v0.0.11"))
        XCTAssertTrue(EngineVersion("v0.0.12")!.isCompatible(with: EngineVersion("v0.0.11")!))
        XCTAssertFalse(EngineVersion("v0.1.0")!.isCompatible(with: EngineVersion("v0.0.11")!))
        for tag in ["../v0.0.11", "v0.0.11-rc1", "v0.0", "v-1.0.0", "v0.0.999999999999999999999"] {
            XCTAssertNil(EngineVersion(tag))
        }
    }

    func testVerifiedInstallRollbackAndFailedUpdatesKeepSelection() throws {
        try inTemporaryFolder { folder in
            let store = EngineStore(root: folder.appendingPathComponent("store"))
            let archive = try makeArchive(folder: folder, version: "0.0.12")
            let release = try metadata(archive: archive, tag: "v0.0.12")
            let installed = try store.install(archive: archive, release: release, bundledVersion: "v0.0.11")
            XCTAssertEqual(store.selected(compatibleWith: "v0.0.11")?.binary, installed.binary)
            XCTAssertNil(store.selected(compatibleWith: "v0.0.13"), "A newer app must not downgrade its bundled engine")
            XCTAssertNil(store.selected(compatibleWith: "v0.1.0"))
            // Executable and Lua tree come from the same immutable directory.
            XCTAssertEqual(installed.binary.deletingLastPathComponent().deletingLastPathComponent(),
                           installed.tex.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
            try Data("corrupt transfer".utf8).write(to: archive)
            XCTAssertThrowsError(try store.install(archive: archive, release: release, bundledVersion: "v0.0.11"))
            XCTAssertEqual(store.selected(compatibleWith: "v0.0.11")?.binary, installed.binary)
            let wrongVersion = try makeArchive(folder: folder, version: "0.0.99")
            XCTAssertThrowsError(try store.install(archive: wrongVersion,
                release: metadata(archive: wrongVersion, tag: "v0.0.13"), bundledVersion: "v0.0.11"))
            XCTAssertEqual(store.selected(compatibleWith: "v0.0.11")?.binary, installed.binary)
            try store.useBundled()
            XCTAssertNil(store.selected(compatibleWith: "v0.0.11"))
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.binary.path),
                          "Rollback must retain packages still used by open app processes")
        }
    }

    func testRejectsIncompleteArchiveLinksAndUntrustedMetadata() throws {
        try inTemporaryFolder { folder in
            let store = EngineStore(root: folder.appendingPathComponent("store"))
            let archive = try makeArchive(folder: folder, version: "0.0.12", link: true)
            let release = try metadata(archive: archive, tag: "v0.0.12")
            XCTAssertThrowsError(try store.install(archive: archive, release: release, bundledVersion: "v0.0.11"))
            XCTAssertFalse(store.hasSelection)
            let incomplete = try makeArchive(folder: folder, version: "0.0.12", incomplete: true)
            XCTAssertThrowsError(try store.install(archive: incomplete,
                release: metadata(archive: incomplete, tag: "v0.0.12"), bundledVersion: "v0.0.11"))
            XCTAssertThrowsError(try metadata(archive: archive, tag: "v0.1.0").asset(bundledVersion: "v0.0.11"))
            XCTAssertThrowsError(try metadata(archive: archive, tag: "v0.0.12", host: "https://example.com").asset(bundledVersion: "v0.0.11"))
            XCTAssertThrowsError(try metadata(archive: archive, tag: "v0.0.12", digest: "sha256:abc").asset(bundledVersion: "v0.0.11"))
            XCTAssertFalse(store.hasSelection)
        }
    }

    func testSelectionRejectsTraversalAndMissingPackage() throws {
        try inTemporaryFolder { folder in
            let store = EngineStore(root: folder)
            for directory in ["../outside", UUID().uuidString] {
                let data = try JSONSerialization.data(withJSONObject: ["directory": directory, "version": "v0.0.12"])
                try data.write(to: folder.appendingPathComponent("selected.json"))
                XCTAssertNil(store.selected(compatibleWith: "v0.0.11"))
            }
        }
    }

    private func inTemporaryFolder(_ action: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("engine-update-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try action(folder)
    }
    private func makeArchive(folder: URL, version: String, link: Bool = false, incomplete: Bool = false) throws -> URL {
        let source = folder.appendingPathComponent(UUID().uuidString)
        let package = source.appendingPathComponent("rtex-test")
        let bin = package.appendingPathComponent("bin")
        let tex = package.appendingPathComponent("share/rtex/tex")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tex.appendingPathComponent("latex"), withIntermediateDirectories: true)
        try "#!/bin/sh\necho 'rtex \(version)'\n".write(to: bin.appendingPathComponent("rtex"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("rtex").path)
        for name in EngineStore.requiredResources where !incomplete {
            try "fixture".write(to: tex.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        if link { try FileManager.default.createSymbolicLink(atPath: package.appendingPathComponent("escape").path,
                                                           withDestinationPath: "../../outside") }
        let archive = folder.appendingPathComponent("\(UUID().uuidString).tar.gz")
        let result = Shell.run("/usr/bin/tar", ["-czf", archive.path, "-C", source.path, "rtex-test"], cwd: folder)
        XCTAssertEqual(result.status, 0, result.output)
        return archive
    }
    private func metadata(archive: URL, tag: String, host: String = "https://github.com", digest: String? = nil) throws -> EngineRelease {
        let data = try Data(contentsOf: archive)
        let name = "rtex-\(EngineRelease.target).tar.gz"
        let info: [String: Any] = ["tag_name": tag, "draft": false, "prerelease": false, "assets": [
            ["name": name, "size": data.count,
             "browser_download_url": "\(host)/kenny-21342/realtime-tex/releases/download/\(tag)/\(name)",
             "digest": digest ?? "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        ]]
        return try JSONDecoder().decode(EngineRelease.self, from: JSONSerialization.data(withJSONObject: info))
    }
}
