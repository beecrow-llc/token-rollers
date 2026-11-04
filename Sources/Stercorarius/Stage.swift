import AppKit

/// A transparent, click-through window covering one display, above all other windows on every
/// Space, full-screen apps included. Hosts walker layers and hides itself while empty.
@MainActor
final class Overlay {
    private let window: NSWindow

    init(screen: NSScreen) {
        window = NSWindow(
            contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        window.contentView = view
        window.setFrame(screen.frame, display: false)
    }

    /// Moves `layer` into this window and shows the window.
    func host(_ layer: CALayer) {
        window.contentView?.layer?.addSublayer(layer)
        window.orderFrontRegardless()
    }

    /// Hides the window once no walker layer is left in it.
    func hideIfEmpty() {
        if window.contentView?.layer?.sublayers?.isEmpty ?? true { hide() }
    }

    func hide() { window.orderOut(nil) }
}

/// Owns one overlay per display and one walker per working session.
@MainActor
final class Stage {
    private let sprites: [Agent: SpriteSheet]
    private var overlays: [CGDirectDisplayID: Overlay] = [:]
    private var walkers: [Session: Walker] = [:]

    /// Share of each sprite's native size at which beetles are drawn.
    var scale: CGFloat = 1 {
        didSet {
            for walker in walkers.values { walker.resize() }
        }
    }

    init(sprites: [Agent: SpriteSheet]) {
        self.sprites = sprites
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// Starts walkers for sessions that began working and retires those whose session stopped.
    func show(_ busy: Set<Session>) {
        for session in busy where walkers[session] == nil {
            guard let sprite = sprites[session.agent] else { continue }
            let walker = Walker(sprite: sprite, stage: self)
            walkers[session] = walker
            walker.start()
        }
        for (session, walker) in walkers where !busy.contains(session) {
            walkers[session] = nil
            walker.retire()
        }
    }

    /// A random display and its overlay, or nil when no display is attached.
    func randomScreen() -> (screen: NSScreen, overlay: Overlay)? {
        guard let screen = NSScreen.screens.randomElement() else { return nil }
        if let overlay = overlays[screen.displayID] { return (screen, overlay) }
        let overlay = Overlay(screen: screen)
        overlays[screen.displayID] = overlay
        return (screen, overlay)
    }

    /// Displays were added, removed or rearranged: rebuild overlays and restart every pass.
    private func screensChanged() {
        for overlay in overlays.values { overlay.hide() }
        overlays = [:]
        for walker in walkers.values { walker.restartPass() }
    }
}

extension NSScreen {
    fileprivate var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}
