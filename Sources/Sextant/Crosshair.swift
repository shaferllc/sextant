import AppKit

/// Fullscreen click-through hairlines that track the pointer across every screen.
/// Needs no permissions at all: the overlay windows ignore mouse events and the
/// pointer is read via NSEvent monitors + NSEvent.mouseLocation.
@MainActor
final class CrosshairController: NSObject, ObservableObject {
    @Published var isActive = false {
        didSet {
            guard oldValue != isActive else { return }
            if isActive { activate() } else { deactivate() }
        }
    }

    /// Fired whenever our overlay windows appear or disappear (the loupe uses
    /// this to keep excluding them from its screen capture).
    var onWindowsChanged: (() -> Void)?

    private let settings: SettingsStore
    private var windows: [OverlayWindow] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: .sextantSettingsChanged, object: nil)
    }

    // MARK: - Lifecycle

    private func activate() {
        rebuildWindows()
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged,
                                             .rightMouseDragged, .otherMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated { self?.update() }
            return event
        }
        update()
        onWindowsChanged?()
    }

    private func deactivate() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        onWindowsChanged?()
    }

    private func rebuildWindows() {
        for window in windows { window.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = OverlayWindow(screen: screen, settings: settings)
            window.orderFrontRegardless()
            return window
        }
    }

    // MARK: - Events

    @objc private func screensChanged(_ note: Notification) {
        guard isActive else { return }
        rebuildWindows()
        update()
        onWindowsChanged?()
    }

    @objc private func settingsChanged(_ note: Notification) {
        guard isActive else { return }
        update()
    }

    private func update() {
        let location = NSEvent.mouseLocation
        for window in windows {
            (window.contentView as? CrosshairView)?.pointerMoved(to: location)
        }
    }
}

// MARK: - Window

private final class OverlayWindow: NSWindow {
    init(screen: NSScreen, settings: SettingsStore) {
        super.init(contentRect: screen.frame, styleMask: .borderless,
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                              .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = CrosshairView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                    settings: settings)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

private final class CrosshairView: NSView {
    private let settings: SettingsStore
    private var pointer = NSPoint(x: -10_000, y: -10_000) // global coords

    init(frame: NSRect, settings: SettingsStore) {
        self.settings = settings
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func pointerMoved(to globalPoint: NSPoint) {
        pointer = globalPoint
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let windowFrame = window?.frame,
              NSMouseInRect(pointer, windowFrame, false) else { return }

        let local = NSPoint(x: pointer.x - windowFrame.minX,
                            y: pointer.y - windowFrame.minY)
        let thickness = max(0.5, CGFloat(settings.crosshairThickness))
        settings.crosshairNSColor.setFill()

        NSRect(x: local.x - thickness / 2, y: 0,
               width: thickness, height: bounds.height).fill()
        NSRect(x: 0, y: local.y - thickness / 2,
               width: bounds.width, height: thickness).fill()

        if settings.showCoordinates {
            drawReadout(at: local)
        }
    }

    /// Pointer position in screen points, top-left origin of the primary
    /// display (the convention screenshots and CGEvent use).
    private func drawReadout(at local: NSPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let text = "\(Int(pointer.x.rounded())), \(Int((primaryHeight - pointer.y).rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let padding = NSSize(width: 6, height: 3)

        var origin = NSPoint(x: local.x + 12, y: local.y + 12)
        if origin.x + size.width + padding.width * 2 > bounds.maxX {
            origin.x = local.x - 12 - size.width - padding.width * 2
        }
        if origin.y + size.height + padding.height * 2 > bounds.maxY {
            origin.y = local.y - 12 - size.height - padding.height * 2
        }

        let box = NSRect(x: origin.x, y: origin.y,
                         width: size.width + padding.width * 2,
                         height: size.height + padding.height * 2)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        string.draw(at: NSPoint(x: box.minX + padding.width,
                                y: box.minY + padding.height))
    }
}
