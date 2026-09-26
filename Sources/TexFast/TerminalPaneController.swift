import AppKit
import Darwin
import SwiftTerm

/// A project-local interactive shell. The PTY and its view are created only
/// when the user first opens the terminal pane.
final class TerminalPaneController: NSViewController, LocalProcessTerminalViewDelegate {
    private let projectDirectory: URL
    private(set) var terminalView: LocalProcessTerminalView!
    var onTitleChanged: ((String) -> Void)?

    init(projectDirectory: URL) {
        self.projectDirectory = projectDirectory
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let terminal = LocalProcessTerminalView(frame: .zero)
        terminal.font = NSFont(name: "DroidSansMonoNerdFontComplete-", size: 12)
            ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.nativeBackgroundColor = .textBackgroundColor
        terminal.nativeForegroundColor = .textColor
        terminal.processDelegate = self
        terminalView = terminal
        view = terminal
    }

    func startIfNeeded() {
        _ = view
        guard !terminalView.process.running else { return }

        let shell = Self.loginShell()
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["SHELL"] = shell
        environment["PATH"] = environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        terminalView.startProcess(executable: shell,
                                  environment: environment.map { "\($0.key)=\($0.value)" },
                                  execName: "-" + URL(fileURLWithPath: shell).lastPathComponent,
                                  currentDirectory: projectDirectory.path)
        onTitleChanged?(projectDirectory.lastPathComponent)
    }

    func focus(in window: NSWindow) { window.makeFirstResponder(terminalView) }

    func stop() {
        if isViewLoaded, terminalView.process.running { terminalView.terminate() }
    }

    deinit { stop() }

    private static func loginShell() -> String {
        if let account = getpwuid(getuid()), let pointer = account.pointee.pw_shell {
            let path = String(cString: pointer)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { [weak self] in self?.onTitleChanged?(title) }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in self?.onTitleChanged?("Shell exited") }
    }
}
