import Foundation
import CryptoKit

public struct EngineVersion: Comparable, Equatable {
    public let numbers: [Int]
    public init?(_ tag: String) {
        let text = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Int($0) != nil }) else { return nil }
        numbers = parts.map { Int($0)! }
    }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
    public func isCompatible(with other: Self) -> Bool { numbers.prefix(2) == other.numbers.prefix(2) }
}

public struct EnginePackage {
    public let binary: URL
    public let tex: URL
    public let version: String
    public init(binary: URL, tex: URL, version: String) {
        self.binary = binary; self.tex = tex; self.version = version
    }
    public static func bundled(in bundle: Bundle = .main) -> Self? {
        let binary = bundle.bundleURL.appendingPathComponent("Contents/MacOS/rtex")
        let resources = bundle.bundleURL.appendingPathComponent("Contents/Resources/rtex")
        guard FileManager.default.isExecutableFile(atPath: binary.path),
              let version = try? String(contentsOf: resources.appendingPathComponent("RELEASE_VERSION"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return Self(binary: binary, tex: resources.appendingPathComponent("tex"), version: version)
    }
    // Fixed for the lifetime of this app process: an update cannot swap Lua files
    // underneath a running session, including sessions opened after installation.
    public static let runtime: EnginePackage? = {
        guard let bundled = bundled() else { return nil }
        return EngineStore().selected(compatibleWith: bundled.version) ?? bundled
    }()
}

public struct EngineUpdateError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct EngineRelease: Decodable {
    public struct Asset: Decodable {
        public let name: String
        public let browser_download_url: URL
        public let digest: String?
        public let size: Int
    }
    public let tag_name: String
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]
    public static var target: String {
        #if arch(arm64)
        return "aarch64-apple-darwin"
        #else
        return "x86_64-apple-darwin"
        #endif
    }
    public func asset(bundledVersion: String) throws -> Asset {
        guard !draft, !prerelease, let version = EngineVersion(tag_name),
              let bundled = EngineVersion(bundledVersion), version.isCompatible(with: bundled) else {
            throw EngineUpdateError("This engine release needs a newer version of TexFast Realtime.")
        }
        let name = "rtex-\(Self.target).tar.gz"
        guard let asset = assets.first(where: { $0.name == name }), asset.size > 0, asset.size <= 100_000_000,
              asset.browser_download_url.absoluteString == "https://github.com/kenny-21342/realtime-tex/releases/download/\(tag_name)/\(name)",
              let digest = asset.digest, digest.hasPrefix("sha256:"),
              digest.count == 71, digest.dropFirst(7).allSatisfy({ $0.isHexDigit }) else {
            throw EngineUpdateError("No SHA-256-verified macOS engine package is available for this Mac.")
        }
        return asset
    }
}

/// Immutable, complete engine packages outside the signed app; only the tiny
/// selection record changes atomically. Old packages remain usable by open apps.
public final class EngineStore {
    public let root: URL
    private let fm = FileManager.default
    private struct Selection: Codable { let directory: String; let version: String }
    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.kenny-lhs.texfast.realtime/Engines", isDirectory: true)
    }
    private var selectionURL: URL { root.appendingPathComponent("selected.json") }
    public var hasSelection: Bool { fm.fileExists(atPath: selectionURL.path) }
    public func selected(compatibleWith version: String) -> EnginePackage? {
        guard let data = try? Data(contentsOf: selectionURL),
              let selection = try? JSONDecoder().decode(Selection.self, from: data),
              UUID(uuidString: selection.directory) != nil,
              let selectedVersion = EngineVersion(selection.version), let bundled = EngineVersion(version),
              selectedVersion >= bundled, selectedVersion.isCompatible(with: bundled) else { return nil }
        let folder = root.appendingPathComponent(selection.directory)
        let package = EnginePackage(binary: folder.appendingPathComponent("bin/rtex"),
                                    tex: folder.appendingPathComponent("share/rtex/tex"), version: selection.version)
        return (try? validate(package)) != nil ? package : nil
    }
    public func useBundled() throws {
        if hasSelection { try fm.removeItem(at: selectionURL) }
    }
    public func install(archive: URL, release: EngineRelease, bundledVersion: String) throws -> EnginePackage {
        let asset = try release.asset(bundledVersion: bundledVersion)
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        let digest = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == asset.size, digest == asset.digest?.lowercased() else {
            throw EngineUpdateError("Engine download failed its SHA-256 integrity check. The current engine was kept.")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let stage = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        // Reject links, devices and path traversal before tar can write anything.
        let entries = try command("/usr/bin/tar", ["-tzf", archive.path], cwd: stage).split(separator: "\n").map(String.init)
        let types = try command("/usr/bin/tar", ["-tvzf", archive.path], cwd: stage).split(separator: "\n")
        guard !entries.isEmpty, entries.count <= 10_000, entries.count == types.count,
              types.allSatisfy({ $0.first == "-" || $0.first == "d" }),
              entries.allSatisfy({ path in
                  !path.hasPrefix("/") && !path.contains("\\") &&
                  !path.split(separator: "/").contains("..") && path.split(separator: "/").count >= 1
              }), Set(entries.compactMap { $0.split(separator: "/").first }).count == 1 else {
            throw EngineUpdateError("The engine archive contains unsafe or unsupported entries.")
        }
        _ = try command("/usr/bin/tar", ["-xzf", archive.path, "-C", stage.path, "--strip-components=1", "--no-same-owner"], cwd: stage)
        let package = EnginePackage(binary: stage.appendingPathComponent("bin/rtex"),
                                    tex: stage.appendingPathComponent("share/rtex/tex"), version: release.tag_name)
        try validate(package)
        let reported = try command(package.binary.path, ["--version"], cwd: stage).trimmingCharacters(in: .whitespacesAndNewlines)
        guard reported == "rtex \(release.tag_name.dropFirst(release.tag_name.hasPrefix("v") ? 1 : 0))" else {
            throw EngineUpdateError("The downloaded engine reports an unexpected version.")
        }
        let directory = UUID().uuidString
        let destination = root.appendingPathComponent(directory, isDirectory: true)
        try fm.moveItem(at: stage, to: destination)
        // If this write fails the old selection is still intact. No existing
        // version directory is ever overwritten or deleted during an update.
        try JSONEncoder().encode(Selection(directory: directory, version: release.tag_name))
            .write(to: selectionURL, options: .atomic)
        return EnginePackage(binary: destination.appendingPathComponent("bin/rtex"),
                             tex: destination.appendingPathComponent("share/rtex/tex"), version: release.tag_name)
    }
    private func validate(_ package: EnginePackage) throws {
        let required = Self.requiredResources
        guard fm.isExecutableFile(atPath: package.binary.path), required.allSatisfy({
            fm.isReadableFile(atPath: package.tex.appendingPathComponent($0).path)
        }) else { throw EngineUpdateError("The engine package is incomplete. The current engine was kept.") }
    }
    private func command(_ path: String, _ args: [String], cwd: URL) throws -> String {
        let result = Shell.run(path, args, cwd: cwd)
        guard result.status == 0 else { throw EngineUpdateError("Engine verification failed: \(result.output.prefix(1000))") }
        return result.output
    }
    static let requiredResources = ["rtex-capture.lua", "rtex-dl.lua", "rtex-serve.lua", "rtex-json.lua",
                                    "rtex-bg.lua", "rtex-pic.lua", "rtex-dl-bin.lua", "latex/rtex-capture.sty",
                                    "latex/rtex-serve-patches.tex", "latex/rtex-literals.tex", "latex/rtex-pic.tex"]
}

public enum EngineUpdates {
    public static func latest(session: URLSession = .shared) async throws -> EngineRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/kenny-21342/realtime-tex/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TexFast-Realtime-Engine-Updater", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try check(response)
        return try JSONDecoder().decode(EngineRelease.self, from: data)
    }
    public static func download(_ asset: EngineRelease.Asset, session: URLSession = .shared) async throws -> URL {
        var request = URLRequest(url: asset.browser_download_url)
        request.timeoutInterval = 120
        let (file, response) = try await session.download(for: request)
        do { try check(response); return file }
        catch { try? FileManager.default.removeItem(at: file); throw error }
    }
    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EngineUpdateError("GitHub could not provide the engine update. Check your connection and try again later.")
        }
    }
}
