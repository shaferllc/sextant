import AppKit

/// Drag-to-measure across every screen.
///
/// A marquee with live width × height, the diagonal, and the angle — the thing
/// you actually want when a designer says "that gutter looks 4pt off". Shift
/// constrains to horizontal, vertical or 45°; guides pull the ends onto
/// themselves; ⌘C copies the numbers; esc puts it away.
@MainActor
final class MeasureController: NSObject, ObservableObject {
    @Published var isActive = false {
        didSet {
            guard oldValue != isActive else { return }
            if isActive { activate() } else { deactivate() }
        }
    }

    /// Fired when the measuring windows appear or disappear.
    var onWindowsChanged: (() -> Void)?

    /// Both ends of the current measurement, in global screen coordinates.
    private(set) var origin: NSPoint?
    private(set) var current: NSPoint = .zero
    private(set) var isDragging = false

    private let settings: SettingsStore
    private let guides: GuideStore
    private var windows: [MeasureWindow] = []
    private var copiedUntil = Date.distantPast

    init(settings: SettingsStore, guides: GuideStore) {
        self.settings = settings
        self.guides = guides
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: - Lifecycle

    private func activate() {
        origin = nil
        isDragging = false
        rebuildWindows()
        NSApp.activate(ignoringOtherApps: true)
        let pointer = NSEvent.mouseLocation
        let key = windows.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? windows.first
        key?.makeKeyAndOrderFront(nil)
        onWindowsChanged?()
    }

    private func deactivate() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        origin = nil
        isDragging = false
        onWindowsChanged?()
    }

    func dismiss() {
        if isActive { isActive = false }
    }

    private func rebuildWindows() {
        for window in windows { window.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = MeasureWindow(contentRect: screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = NSColor.black.withAlphaComponent(0.001)
            window.hasShadow = false
            window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                         .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            window.contentView = MeasureView(
                frame: NSRect(origin: .zero, size: screen.frame.size), controller: self)
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            return window
        }
    }

    @objc private func screensChanged(_ note: Notification) {
        guard isActive else { return }
        rebuildWindows()
        onWindowsChanged?()
    }

    // MARK: - Dragging

    private func adjust(_ point: NSPoint, shift: Bool) -> NSPoint {
        var result = point
        if settings.snapToGuides {
            result = guides.snapped(result, within: 6)
        }
        guard shift, let start = origin else { return result }
        let dx = result.x - start.x
        let dy = result.y - start.y
        if abs(abs(dx) - abs(dy)) < min(abs(dx), abs(dy)) * 0.5 {
            // Near enough to the diagonal: lock to exactly 45°.
            let side = min(abs(dx), abs(dy))
            return NSPoint(x: start.x + (dx < 0 ? -side : side),
                           y: start.y + (dy < 0 ? -side : side))
        }
        return abs(dx) > abs(dy)
            ? NSPoint(x: result.x, y: start.y)
            : NSPoint(x: start.x, y: result.y)
    }

    fileprivate func beginDrag(at point: NSPoint, shift: Bool) {
        origin = settings.snapToGuides ? guides.snapped(point, within: 6) : point
        current = origin ?? point
        isDragging = true
        redraw()
    }

    fileprivate func updateDrag(to point: NSPoint, shift: Bool) {
        guard isDragging else { return }
        current = adjust(point, shift: shift)
        redraw()
    }

    fileprivate func endDrag(at point: NSPoint, shift: Bool) {
        guard isDragging else { return }
        current = adjust(point, shift: shift)
        isDragging = false
        redraw()
    }

    private func redraw() {
        for window in windows { window.contentView?.needsDisplay = true }
    }

    // MARK: - Readout

    /// Width, height, diagonal and angle of the current measurement.
    var measurement: (rect: NSRect, distance: CGFloat, angle: CGFloat)? {
        guard let origin else { return nil }
        let rect = NSRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
                          width: abs(current.x - origin.x),
                          height: abs(current.y - origin.y))
        let dx = current.x - origin.x
        let dy = current.y - origin.y
        let distance = sqrt(dx * dx + dy * dy)
        // Screen convention: y grows downward, so flip dy for a sane angle.
        var angle = atan2(-dy, dx) * 180 / .pi
        if angle < 0 { angle += 360 }
        return (rect, distance, angle)
    }

    var summary: String? {
        guard let measurement else { return nil }
        let width = Int(measurement.rect.width.rounded())
        let height = Int(measurement.rect.height.rounded())
        let distance = Int(measurement.distance.rounded())
        return "\(width) × \(height) pt · \(distance) pt · \(Int(measurement.angle.rounded()))°"
    }

    fileprivate var recentlyCopied: Bool { Date() < copiedUntil }

    func copySummary() {
        guard let summary else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summary, forType: .string)
        copiedUntil = Date().addingTimeInterval(0.9)
        redraw()
    }

    /// Turns the current measurement into a pair of sticky guides.
    func convertToGuides() {
        guard let origin else { return }
        guides.drop(.vertical, at: Double(origin.x))
        guides.drop(.horizontal, at: Double(origin.y))
        guides.drop(.vertical, at: Double(current.x))
        guides.drop(.horizontal, at: Double(current.y))
    }
}

// MARK: - Window

private final class MeasureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

private final class MeasureView: NSView {
    private unowned let controller: MeasureController

    init(frame: NSRect, controller: MeasureController) {
        self.controller = controller
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var windowFrame: NSRect { window?.frame ?? .zero }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        controller.beginDrag(at: NSEvent.mouseLocation,
                             shift: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        controller.updateDrag(to: NSEvent.mouseLocation,
                              shift: event.modifierFlags.contains(.shift))
    }

    override func mouseUp(with event: NSEvent) {
        controller.endDrag(at: NSEvent.mouseLocation,
                           shift: event.modifierFlags.contains(.shift))
    }

    override func rightMouseDown(with event: NSEvent) {
        controller.dismiss()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            controller.copySummary()
            return
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "g":
            controller.convertToGuides()
        default:
            if event.keyCode == 53 { // esc
                controller.dismiss()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            controller.copySummary()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let measurement = controller.measurement, let origin = controller.origin else {
            drawHint()
            return
        }

        let frame = windowFrame
        let rect = measurement.rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let start = NSPoint(x: origin.x - frame.minX, y: origin.y - frame.minY)
        let end = NSPoint(x: controller.current.x - frame.minX,
                          y: controller.current.y - frame.minY)

        NSColor.black.withAlphaComponent(0.28).setFill()
        rect.fill(using: .sourceOver)

        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1
        border.setLineDash([5, 3], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        border.stroke()

        let diagonal = NSBezierPath()
        diagonal.move(to: start)
        diagonal.line(to: end)
        diagonal.lineWidth = 1
        NSColor.systemYellow.withAlphaComponent(0.9).setStroke()
        diagonal.stroke()

        for point in [start, end] {
            let dot = NSRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
            NSColor.systemYellow.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }

        drawLabel(for: measurement, near: end)
    }

    private func drawHint() {
        let text = "Drag to measure  ·  ⇧ constrain  ·  ⌘C copy  ·  G to guides  ·  esc"
        draw(badge: text, at: NSPoint(x: bounds.midX, y: bounds.midY),
             centred: true, color: .white)
    }

    private func drawLabel(for measurement: (rect: NSRect, distance: CGFloat, angle: CGFloat),
                           near point: NSPoint) {
        let width = Int(measurement.rect.width.rounded())
        let height = Int(measurement.rect.height.rounded())
        let distance = Int(measurement.distance.rounded())
        let angle = Int(measurement.angle.rounded())
        let text = controller.recentlyCopied
            ? "Copied"
            : "\(width) × \(height)   ⟋ \(distance)   ∠ \(angle)°"
        draw(badge: text,
             at: NSPoint(x: point.x + 14, y: point.y + 14),
             centred: false,
             color: controller.recentlyCopied ? .systemGreen : .white)
    }

    private func draw(badge text: String, at point: NSPoint, centred: Bool, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let padding = NSSize(width: 8, height: 5)
        var origin = point
        if centred {
            origin.x -= (size.width + padding.width * 2) / 2
            origin.y -= (size.height + padding.height * 2) / 2
        } else {
            if origin.x + size.width + padding.width * 2 > bounds.maxX {
                origin.x = point.x - 14 - size.width - padding.width * 2
            }
            if origin.y + size.height + padding.height * 2 > bounds.maxY {
                origin.y = point.y - 14 - size.height - padding.height * 2
            }
        }

        let box = NSRect(x: origin.x, y: origin.y,
                         width: size.width + padding.width * 2,
                         height: size.height + padding.height * 2)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        string.draw(at: NSPoint(x: box.minX + padding.width, y: box.minY + padding.height))
    }
}
