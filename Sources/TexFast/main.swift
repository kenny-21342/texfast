import AppKit
import TexFastCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [MainWindowController] = []
    private var homeController: HomeWindowController?
    private var aboutController: AboutWindowController?
    private var settingsController: SettingsWindowController?
    private var finalRenderWindow: NSWindow?
    private var finalRenderLabel: NSTextField?
    private var finalRenderProgress: NSProgressIndicator?
    private var isRenderingOnQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        // A path on the command line opens straight away; otherwise ask.
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first {
            openDocument(at: URL(fileURLWithPath: path).standardizedFileURL)
        } else {
            showHome(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isRenderingOnQuit { return .terminateLater }
        guard !controllers.isEmpty else { return .terminateNow }

        for controller in controllers {
            if let error = controller.prepareForFinalRender() {
                let alert = NSAlert()
                alert.messageText = "Final render could not start"
                alert.informativeText = error
                alert.runModal()
                return .terminateCancel
            }
        }

        isRenderingOnQuit = true
        controllers.forEach { $0.setEditingEnabled(false) }
        showFinalRenderWindow()
        renderNextDocument(at: 0)
        return .terminateLater
    }

    private func showFinalRenderWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 115),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Rendering final PDF"
        window.center()
        let content = NSView(frame: window.contentView!.bounds)
        let label = NSTextField(labelWithString: "Preparing final PDF…")
        label.frame = NSRect(x: 22, y: 65, width: 386, height: 24)
        let progress = NSProgressIndicator(frame: NSRect(x: 22, y: 30, width: 386, height: 18))
        progress.isIndeterminate = true
        progress.style = .bar
        content.addSubview(label)
        content.addSubview(progress)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        finalRenderWindow = window
        finalRenderLabel = label
        finalRenderProgress = progress
        progress.startAnimation(nil)
    }

    private func renderNextDocument(at index: Int) {
        guard index < controllers.count else {
            finalRenderWindow?.close()
            finalRenderWindow = nil
            finalRenderLabel = nil
            finalRenderProgress = nil
            isRenderingOnQuit = false
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        controllers[index].renderFinal(onProgress: { [weak self] message, fraction in
            guard let self else { return }
            finalRenderLabel?.stringValue = message
            if let fraction {
                finalRenderProgress?.stopAnimation(nil)
                finalRenderProgress?.isIndeterminate = false
                finalRenderProgress?.doubleValue = fraction * 100
            } else {
                finalRenderProgress?.isIndeterminate = true
                finalRenderProgress?.startAnimation(nil)
            }
        }, finished: { [weak self] error in
            guard let self else { return }
            if let error {
                finalRenderWindow?.close()
                finalRenderWindow = nil
                isRenderingOnQuit = false
                controllers.forEach { $0.setEditingEnabled(true) }
                NSApp.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.messageText = "Final render failed"
                alert.informativeText = error
                alert.runModal()
            } else {
                renderNextDocument(at: index + 1)
            }
        })
    }

    func applicationWillTerminate(_ notification: Notification) {
        controllers.forEach { $0.shutDown() }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openDocument(at: URL(fileURLWithPath: filename))
        return true
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "tex")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openDocument(at: url)
    }

    @objc func showHome(_ sender: Any?) {
        if homeController == nil {
            let home = HomeWindowController()
            home.home.onChooseFile = { [weak self] in self?.openDocument(nil) }
            home.home.onOpen = { [weak self] url in self?.openDocument(at: url) }
            homeController = home
        }
        homeController?.home.reload()
        homeController?.showWindow(nil)
        homeController?.window?.makeKeyAndOrderFront(nil)
        homeController?.home.focusDefaultAction()
    }

    @objc func showAbout(_ sender: Any?) {
        if aboutController == nil { aboutController = AboutWindowController() }
        aboutController?.showWindow(nil)
        aboutController?.window?.makeKeyAndOrderFront(nil)
        aboutController?.window?.makeFirstResponder(nil)
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsController == nil { settingsController = SettingsWindowController() }
        settingsController?.settings.refresh()
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    private func openDocument(at url: URL) {
        let url = url.resolvingSymlinksInPath().standardizedFileURL
        if let existing = controllers.first(where: { $0.documentURL == url }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        RecentFiles.note(url)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)   // also feeds the Dock menu
        let controller = MainWindowController(fileURL: url)
        controllers.append(controller)
        controller.showWindow(nil)
        homeController?.home.reload()
    }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = appMenu.addItem(withTitle: "About TexFast", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide TexFast", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit TexFast", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Home", action: #selector(showHome(_:)), keyEquivalent: "H")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        let save = fileMenu.addItem(withTitle: "Save and Build", action: #selector(MainWindowController.saveDocument(_:)), keyEquivalent: "s")
        save.target = nil
        fileMenu.addItem(.separator())
        // No key equivalent: in this hand-built menu only plain-⌘ equivalents
        // dispatch — ⇧⌘ and ⌥⌘ variants silently never fire — and every sensible
        // plain-⌘ key here is either taken or misleading. It is a setting you
        // flip rarely, so the menu item alone is honest.
        let auto = fileMenu.addItem(withTitle: "Auto-compile on Save",
                                    action: #selector(MainWindowController.toggleAutoCompile(_:)),
                                    keyEquivalent: "")
        auto.target = nil
        fileMenu.addItem(.separator())
        // Same actions as the home list's context menu, reachable from the
        // menu bar so they work without a right-click.
        let forget = fileMenu.addItem(withTitle: "Remove Selected from Recents",
                                      action: #selector(HomeViewController.removeSelected(_:)),
                                      keyEquivalent: "")
        forget.target = nil
        let clear = fileMenu.addItem(withTitle: "Clear Recent Files",
                                     action: #selector(HomeViewController.clearAll(_:)),
                                     keyEquivalent: "")
        clear.target = nil
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // performTextFinderAction: dispatches on the item's tag. Leaving it at
        // the default 0 is not "show the find bar" — it is not a valid
        // NSTextFinder.Action at all, so ⌘F would do nothing.
        let find = editMenu.addItem(withTitle: "Find…", action: Selector(("performTextFinderAction:")), keyEquivalent: "f")
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        let findNext = editMenu.addItem(withTitle: "Find Next", action: Selector(("performTextFinderAction:")), keyEquivalent: "g")
        findNext.tag = NSTextFinder.Action.nextMatch.rawValue
        let findPrevious = editMenu.addItem(withTitle: "Find Previous", action: Selector(("performTextFinderAction:")), keyEquivalent: "G")
        findPrevious.keyEquivalentModifierMask = [.command, .shift]
        findPrevious.tag = NSTextFinder.Action.previousMatch.rawValue
        let useSelection = editMenu.addItem(withTitle: "Use Selection for Find",
                                            action: Selector(("performTextFinderAction:")),
                                            keyEquivalent: "e")
        useSelection.tag = NSTextFinder.Action.setSearchString.rawValue
        let replace = editMenu.addItem(withTitle: "Find and Replace…", action: Selector(("performTextFinderAction:")), keyEquivalent: "f")
        replace.keyEquivalentModifierMask = [.command, .option]
        replace.tag = NSTextFinder.Action.showReplaceInterface.rawValue
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(MainWindowController.toggleOutline(_:)), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Toggle Terminal", action: #selector(MainWindowController.toggleTerminal(_:)), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Toggle Problems", action: #selector(MainWindowController.toggleProblems(_:)), keyEquivalent: "2")
        viewMenu.addItem(withTitle: "Show in Preview", action: #selector(MainWindowController.syncToPreview(_:)), keyEquivalent: "j")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }
}

// A language server that dies mid-write must not take the editor with it.
Shell.ignoreBrokenPipes()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
