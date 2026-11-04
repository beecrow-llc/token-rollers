import AppKit

/// Polls session records once a second and keeps one beetle per working session on screen.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let scanner: SessionScanner = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directories = Agent.allCases.map { ($0, $0.sessionDirectory(home: home)) }
        return SessionScanner(directories: Dictionary(uniqueKeysWithValues: directories))
    }()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var sizeItems: [NSMenuItem] = []
    private var stage: Stage?
    private var statusItem: NSStatusItem?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let sprites: [Agent: SpriteSheet]
        do {
            sprites = try Dictionary(
                uniqueKeysWithValues: Agent.allCases.map { ($0, try SpriteSheet.bundled(for: $0)) })
        } catch {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Stercorarius cannot load its sprites"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let size = BeetleSize.saved(in: .standard)
        let stage = Stage(sprites: sprites)
        stage.scale = size.rawValue
        self.stage = stage
        statusItem = makeStatusItem(size: size)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let busy = scanner.busySessions()
        stage?.show(busy)
        statusLine.title = Agent.allCases
            .map { agent in "\(agent.displayName) \(busy.count { $0.agent == agent })" }
            .joined(separator: " · ")
    }

    private func makeStatusItem(size: BeetleSize) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "ladybug.fill", accessibilityDescription: "Stercorarius")
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(makeSizeMenu(checked: size))
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(
                title: "Quit Stercorarius", action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))
        item.menu = menu
        return item
    }

    /// The "Beetle Size" submenu, with `checked` ticked.
    private func makeSizeMenu(checked: BeetleSize) -> NSMenuItem {
        let submenu = NSMenu()
        for size in BeetleSize.allCases {
            let item = NSMenuItem(
                title: size.title, action: #selector(chooseSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size.rawValue
            item.state = size == checked ? .on : .off
            submenu.addItem(item)
            sizeItems.append(item)
        }
        let parent = NSMenuItem(title: "Beetle Size", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? Double, let size = BeetleSize(rawValue: raw)
        else { return }
        size.save(in: .standard)
        stage?.scale = size.rawValue
        for item in sizeItems { item.state = item === sender ? .on : .off }
    }
}
