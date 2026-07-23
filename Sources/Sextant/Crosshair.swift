import AppKit

/// The click-through drawing layer: hairlines that track the pointer, sticky
/// guides, and the layout grid. All three share one set of fullscreen overlay
/// windows so they stack in a predictable order and cost one window per screen.
///
/// Needs no permissions at all: the windows ignore mouse events and the pointer
/// is read via NSEvent monitors + NSEvent.mouseLocation.
@MainActor
final class CrosshairController: NSObject, ObservableObject {
    /// The hairlines through the pointer.
    @Published var isActive = false {
        didSet {
            guard oldValue != isActive else { return }
            syncWindows()
            if isActive { startTracking() } else { stopTracking() }
        }
    }

    /// The column / baseline grid.
    @Published var showGrid = false {
        didSet {
            guard oldValue != showGrid else { return }
            syncWindows()
        }
    }

    /// Fired whenever our overlay windows appear or disappear (the loupe uses
    /// this to keep excluding them from its screen capture).
    var onWindowsChanged: (() -> Void)?

    private let settings: SettingsStore
    private let guides: GuideStore
    private var windows: [OverlayWindow] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(settings: SettingsStore, guides: GuideStore) {
        self.settings = settings
        self.guides = guides
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: .sextantSettingsChanged, object: nil)
    }

    /// True when anything at all wants to be on screen.
    private var wantsWindows: Bool {
        isActive || showGrid || !guides.isEmpty
    }

    /// Call after guides change so the overlay appears, disappears, or redraws.
    func guidesChanged() {
        syncWindows()
        redraw()
    }

    // MARK: - Lifecycle

    private func syncWindows() {
        if wantsWindows {
            if windows.isEmpty {
                rebuildWindows()
                onWindowsChanged?()
            }
            update()
        } else if !windows.isEmpty {
            for window in windows { window.orderOut(nil) }
            windows.removeAll()
            onWindowsChanged?()
        }
    }

    private func startTracking() {
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
    }

    private func stopTracking() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func rebuildWindows() {
        for window in windows { window.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = OverlayWindow(screen: screen, settings: settings, guides: guides,
                                       controller: self)
            window.orderFrontRegardless()
            return window
        }
    }

    // MARK: - Events

    @objc private func screensChanged(_ note: Notification) {
        guard !windows.isEmpty else { return }
        rebuildWindows()
        update()
        onWindowsChanged?()
    }

    @objc private func settingsChanged(_ note: Notification) {
        redraw()
    }

    private func redraw() {
        for window in windows { window.contentView?.needsDisplay = true }
    }

    private func update() {
        var location = NSEvent.mouseLocation
        if settings.snapToGuides {
            location = guides.snapped(location, within: 6)
        }
        for window in windows {
            (window.contentView as? OverlayView)?.pointerMoved(to: location)
        }
    }

    /// Whether the hairlines should draw — the view asks, because the same
    /// window also carries the grid and guides.
    var drawsCrosshair: Bool { isActive }
    var drawsGrid: Bool { showGrid }
}

// MARK: - Window

private final class OverlayWindow: NSWindow {
    init(screen: NSScreen, settings: SettingsStore, guides: GuideStore,
         controller: CrosshairController) {
        super.init(contentRect: screen.frame, styleMask: .borderless,
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                              .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                  settings: settings, guides: guides, controller: controller)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

private final class OverlayView: NSView {
    private let settings: SettingsStore
    private let guides: GuideStore
    private unowned let controller: CrosshairController
    private var pointer = NSPoint(x: -10_000, y: -10_000) // global coords

    init(frame: NSRect, settings: SettingsStore, guides: GuideStore,
         controller: CrosshairController) {
        self.settings = settings
        self.guides = guides
        self.controller = controller
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func pointerMoved(to globalPoint: NSPoint) {
        pointer = globalPoint
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if controller.drawsGrid { drawGrid() }
        drawGuides()
        if controller.drawsCrosshair { drawCrosshair() }
    }

    /// Window frame in global coordinates — everything is drawn relative to it.
    private var windowFrame: NSRect { window?.frame ?? .zero }

    // MARK: Grid

    private func drawGrid() {
        let columns = max(1, settings.gridColumns)
        let gutter = max(0, CGFloat(settings.gridGutter))
        let margin = max(0, CGFloat(settings.gridMargin))
        let color = settings.gridNSColor

        let usable = bounds.width - margin * 2 - gutter * CGFloat(columns - 1)
        guard usable > 0 else { return }
        let columnWidth = usable / CGFloat(columns)

        color.withAlphaComponent(color.alphaComponent * 0.55).setFill()
        var x = margin
        for _ in 0..<columns {
            NSRect(x: x, y: 0, width: columnWidth, height: bounds.height).fill()
            x += columnWidth + gutter
        }

        let baseline = CGFloat(settings.gridBaseline)
        guard baseline >= 2 else { return }
        color.withAlphaComponent(color.alphaComponent * 0.5).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 0.5
        var y = bounds.height
        while y >= 0 {
            path.move(to: NSPoint(x: 0, y: y))
            path.line(to: NSPoint(x: bounds.width, y: y))
            y -= baseline
        }
        path.stroke()
    }

    // MARK: Guides

    private func drawGuides() {
        guard !guides.isEmpty else { return }
        let frame = windowFrame
        NSColor.systemTeal.withAlphaComponent(0.85).setFill()
        for guide in guides.guides {
            switch guide.orientation {
            case .vertical:
                let x = CGFloat(guide.position) - frame.minX
                guard x >= 0, x <= bounds.width else { continue }
                NSRect(x: x - 0.5, y: 0, width: 1, height: bounds.height).fill()
            case .horizontal:
                let y = CGFloat(guide.position) - frame.minY
                guard y >= 0, y <= bounds.height else { continue }
                NSRect(x: 0, y: y - 0.5, width: bounds.width, height: 1).fill()
            }
        }
    }

    // MARK: Crosshair

    private func drawCrosshair() {
        let frame = windowFrame
        guard NSMouseInRect(pointer, frame, false) else { return }

        let local = NSPoint(x: pointer.x - frame.minX, y: pointer.y - frame.minY)
        let thickness = max(0.5, CGFloat(settings.crosshairThickness))
        let gap = max(0, CGFloat(settings.crosshairGap))
        let color = settings.crosshairNSColor

        if settings.crosshairDashed {
            color.setStroke()
            let path = NSBezierPath()
            path.lineWidth = thickness
            path.setLineDash([6, 4], count: 2, phase: 0)
            if gap > 0 {
                path.move(to: NSPoint(x: local.x, y: 0))
                path.line(to: NSPoint(x: local.x, y: local.y - gap))
                path.move(to: NSPoint(x: local.x, y: local.y + gap))
                path.line(to: NSPoint(x: local.x, y: bounds.height))
                path.move(to: NSPoint(x: 0, y: local.y))
                path.line(to: NSPoint(x: local.x - gap, y: local.y))
                path.move(to: NSPoint(x: local.x + gap, y: local.y))
                path.line(to: NSPoint(x: bounds.width, y: local.y))
            } else {
                path.move(to: NSPoint(x: local.x, y: 0))
                path.line(to: NSPoint(x: local.x, y: bounds.height))
                path.move(to: NSPoint(x: 0, y: local.y))
                path.line(to: NSPoint(x: bounds.width, y: local.y))
            }
            path.stroke()
        } else {
            color.setFill()
            if gap > 0 {
                NSRect(x: local.x - thickness / 2, y: 0,
                       width: thickness, height: max(0, local.y - gap)).fill()
                NSRect(x: local.x - thickness / 2, y: local.y + gap,
                       width: thickness, height: max(0, bounds.height - local.y - gap)).fill()
                NSRect(x: 0, y: local.y - thickness / 2,
                       width: max(0, local.x - gap), height: thickness).fill()
                NSRect(x: local.x + gap, y: local.y - thickness / 2,
                       width: max(0, bounds.width - local.x - gap), height: thickness).fill()
            } else {
                NSRect(x: local.x - thickness / 2, y: 0,
                       width: thickness, height: bounds.height).fill()
                NSRect(x: 0, y: local.y - thickness / 2,
                       width: bounds.width, height: thickness).fill()
            }
        }

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
