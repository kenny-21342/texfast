import Foundation

public struct RunResult {
    public let status: Int32
    public let output: String
    public let duration: Double
}

public enum Shell {
    /// Called once by each front end: subprocess pipes must never raise SIGPIPE.
    public static func ignoreBrokenPipes() { signal(SIGPIPE, SIG_IGN) }

    /// Run an executable found on PATH, capturing merged stdout/stderr.
    @discardableResult
    public static func run(_ launchPath: String,
                    _ args: [String],
                    cwd: URL,
                    env extra: [String: String] = [:],
                    cancellation: BuildCancellation? = nil,
                    onOutput: ((String) -> Void)? = nil) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        p.currentDirectoryURL = cwd

        var env = ProcessInfo.processInfo.environment
        // swiftly points TOOLCHAINS at a toolchain that may not exist; never
        // let that leak into the TeX subprocesses.
        env.removeValue(forKey: "TOOLCHAINS")
        for (k, v) in extra { env[k] = v }
        p.environment = env

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        let start = Date()
        if let cancellation, !cancellation.register(p) {
            return RunResult(status: -1, output: "build cancelled", duration: 0)
        }
        defer { cancellation?.unregister(p) }
        do { try p.run() } catch {
            return RunResult(status: 127, output: "failed to launch \(launchPath): \(error)", duration: 0)
        }
        cancellation?.didLaunch(p)
        // Drain concurrently so a chatty child cannot deadlock on a full pipe.
        var data = Data()
        let q = DispatchQueue(label: "drain")
        let done = DispatchSemaphore(value: 0)
        q.async {
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                onOutput?(String(decoding: chunk, as: UTF8.self))
            }
            done.signal()
        }
        p.waitUntilExit()
        done.wait()

        return RunResult(status: cancellation?.isCancelled == true ? -1 : p.terminationStatus,
                         output: String(data: data, encoding: .utf8) ?? "",
                         duration: Date().timeIntervalSince(start))
    }

    public static func which(_ name: String) -> String? {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = String(dir) + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        for candidate in ["/Library/TeX/texbin/\(name)", "/usr/bin/\(name)", "/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

public func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("fastex: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

/// Stderr logging, so stdout stays clean for machine-readable output.
public func log(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}
