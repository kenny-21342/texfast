import AppKit
import TexFastCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [MainWindowController] = []
    private var homeController: HomeWindowController?

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
    }

    private func openDocument(at url: URL) {
        let url = url.standardizedFileURL
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
        appMenu.addItem(withTitle: "About TexFast", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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
        viewMenu.addItem(withTitle: "Toggle Outline", action: #selector(MainWindowController.toggleOutline(_:)), keyEquivalent: "0")
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
