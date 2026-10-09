import Foundation

/// Stops subprocesses belonging to an obsolete draft build. A final build
/// never shares this token with a preview, so cancelling edits cannot stop it.
public final class BuildCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var processes: [Process] = []

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let active = processes
        lock.unlock()
        for process in active where process.isRunning {
            _ = kill(process.processIdentifier, SIGTERM)
        }
    }

    func register(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        processes.append(process)
        return true
    }

    func didLaunch(_ process: Process) {
        if isCancelled && process.isRunning {
            _ = kill(process.processIdentifier, SIGTERM)
        }
    }

    func unregister(_ process: Process) {
        lock.lock()
        processes.removeAll { $0 === process }
        lock.unlock()
    }
}
