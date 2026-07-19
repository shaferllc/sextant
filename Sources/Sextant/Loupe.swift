import AppKit
import ScreenCaptureKit

/// One rendered loupe frame, handed from the capture loop to the view.
struct LoupeFrame {
    let image: CGImage
    /// The region we wanted, in display-local points, top-left origin.
    let desired: CGRect
    /// The region actually captured (desired clamped to the display).
    let clamped: CGRect
    /// Display backing scale (capture pixels per source point).
    let scale: CGFloat
    /// View points per source point.
    let zoom: CGFloat
    /// Pointer position in display-local points, top-left origin.
    let cursor: CGPoint
    let hex: String
}

/// A circular magnifier that floats beside the pointer, refreshed ~30 fps via
/// ScreenCaptureKit screenshots of a small region around the cursor.
@MainActor
final class LoupeController: NSObject, ObservableObject {
    static let diameter: CGFloat = 176
    static let labelStrip: CGFloat = 34
    static let zoomSteps: [CGFloat] = [2, 4, 8, 16, 32]

    @Published var isActive = false {
        didSet {
            guard oldValue != isActive, !suppressSideEffects else { return }
            if isActive {
                if !tryActivate() {
                    suppressSideEffects = true
                    isActive = false
                    suppressSideEffects = false
                }
            } else {
                deactivate()
            }
        }
    }

    private(set) var zoom: CGFloat = 8

    private let settings: SettingsStore
    private var suppressSideEffects = false
    private var window: LoupeWindow?
    private var loupeView: LoupeView?
    private var timer: Timer?
    private var content: SCShareableContent?
    private var contentDirty = true
    private var cachedFilter: SCContentFilter?
    private var cachedFilterDisplayID: CGDirectDisplayID = 0
    private var inFlight = false

    init(settings: SettingsStore) {
        self.settings = settings
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// The crosshair overlays came or went; rebuild the exclusion filter.
    func noteWindowsChanged() {
        contentDirty = true
        cachedFilter = nil
    }

    @objc private func screensChanged(_ note: Notification) {
        contentDirty = true
        cachedFilter = nil
    }

    // MARK: - Lifecycle

    private func tryActivate() -> Bool {
        guard CGPreflightScreenCaptureAccess() else {
            // First-ever ask triggers the system prompt; either way, explain.
            CGRequestScreenCaptureAccess()
            PermissionExplainer.shared.show { [weak self] in
                self?.isActive = true
            }
            return false
        }

        zoom = Self.zoomSteps.min(by: {
            abs($0 - settings.defaultZoom) < abs($1 - settings.defaultZoom)
        }) ?? 8

        let size = NSSize(width: Self.diameter, height: Self.diameter + Self.labelStrip)
        let window = LoupeWindow(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        let view = LoupeView(frame: NSRect(origin: .zero, size: size), controller: self)
        window.contentView = view
        self.window = window
        self.loupeView = view

        positionWindow()
        window.orderFrontRegardless()
        // Take key focus so + / − / ⌘C work while the loupe is up.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        contentDirty = true
        let timer = Timer(timeInterval: 1.0 / 30.0, target: self,
                          selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        return true
    }

    private func deactivate() {
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window = nil
        loupeView = nil
        inFlight = false
    }

    func dismiss() {
        if isActive { isActive = false }
    }

    // MARK: - Interaction

    func adjustZoom(by delta: Int) {
        guard let index = Self.zoomSteps.firstIndex(of: zoom) else {
            zoom = 8
            return
        }
        let next = min(max(index + delta, 0), Self.zoomSteps.count - 1)
        zoom = Self.zoomSteps[next]
    }

    func copyHex() {
        guard let hex = loupeView?.currentHex else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(hex, forType: .string)
        loupeView?.flashCopied()
    }

    // MARK: - Capture loop

    @objc private func tick(_ timer: Timer) {
        guard isActive else { return }
        positionWindow()
        guard !inFlight else { return }
        inFlight = true
        Task { [weak self] in
            await self?.captureFrame()
            self?.inFlight = false
        }
    }

    private func positionWindow() {
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(pointer, $0.frame, false)
        }) ?? NSScreen.main else { return }

        let size = window.frame.size
        let gap: CGFloat = 22
        var origin = NSPoint(x: pointer.x + gap, y: pointer.y + gap)
        if origin.x + size.width > screen.frame.maxX {
            origin.x = pointer.x - gap - size.width
        }
        if origin.y + size.height > screen.frame.maxY {
            origin.y = pointer.y - gap - size.height
        }
        window.setFrameOrigin(origin)
    }

    private func captureFrame() async {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(pointer, $0.frame, false)
        }) ?? NSScreen.main else { return }
        let displayID = Self.displayID(of: screen)

        if contentDirty || content == nil {
            contentDirty = false
            content = try? await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: true)
            cachedFilter = nil
        }
        guard let content,
              let display = content.displays.first(where: { $0.displayID == displayID })
        else { return }

        if cachedFilter == nil || cachedFilterDisplayID != displayID {
            let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
            let ourWindows = content.windows.filter { $0.owningApplication?.processID == pid }
            cachedFilter = SCContentFilter(display: display, excludingWindows: ourWindows)
            cachedFilterDisplayID = displayID
        }
        guard let filter = cachedFilter else { return }

        let scale = screen.backingScaleFactor
        let side = Self.diameter / zoom
        let localX = pointer.x - screen.frame.minX
        let localYTop = screen.frame.maxY - pointer.y
        var desired = CGRect(x: localX - side / 2, y: localYTop - side / 2,
                             width: side, height: side)
        desired.origin.x = floor(desired.origin.x * scale) / scale
        desired.origin.y = floor(desired.origin.y * scale) / scale

        let displayBounds = CGRect(x: 0, y: 0,
                                   width: CGFloat(display.width),
                                   height: CGFloat(display.height))
        var clamped = desired.intersection(displayBounds)
        guard !clamped.isEmpty else { return }
        // Align to the pixel grid so magnified pixels stay crisp.
        let minX = floor(clamped.minX * scale) / scale
        let minY = floor(clamped.minY * scale) / scale
        let maxX = ceil(clamped.maxX * scale) / scale
        let maxY = ceil(clamped.maxY * scale) / scale
        clamped = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        let config = SCStreamConfiguration()
        config.sourceRect = clamped
        config.width = max(1, Int((clamped.width * scale).rounded()))
        config.height = max(1, Int((clamped.height * scale).rounded()))
        config.showsCursor = false

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            guard isActive else { return }
            let cursor = CGPoint(x: localX, y: localYTop)
            let hex = Self.hexColor(of: image, at: cursor, in: clamped)
            loupeView?.present(LoupeFrame(image: image, desired: desired,
                                          clamped: clamped, scale: scale,
                                          zoom: zoom, cursor: cursor, hex: hex))
        } catch {
            // Permission may have been revoked mid-flight; anything else is a
            // transient capture hiccup and the next tick will retry.
            if !CGPreflightScreenCaptureAccess() {
                dismiss()
                PermissionExplainer.shared.show { [weak self] in
                    self?.isActive = true
                }
            }
        }
    }

    // MARK: - Helpers

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }

    /// Samples the captured image at the pointer position and returns #RRGGBB.
    private static func hexColor(of image: CGImage, at cursor: CGPoint,
                                 in clamped: CGRect) -> String {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, clamped.width > 0, clamped.height > 0 else {
            return "#000000"
        }
        let fx = (cursor.x - clamped.minX) / clamped.width
        let fy = (cursor.y - clamped.minY) / clamped.height
        let px = min(max(Int(fx * CGFloat(width)), 0), width - 1)
        let py = min(max(Int(fy * CGFloat(height)), 0), height - 1)

        var pixel = [UInt8](repeating: 0, count: 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(data: &pixel, width: 1, height: 1,
                                      bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: info) else { return "#000000" }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: -CGFloat(px),
                                       y: -CGFloat(height - 1 - py),
                                       width: CGFloat(width),
                                       height: CGFloat(height)))
        return String(format: "#%02X%02X%02X", pixel[0], pixel[1], pixel[2])
    }
}

// MARK: - Window

private final class LoupeWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

@MainActor
final class LoupeView: NSView {
    private unowned let controller: LoupeController
    private var frameData: LoupeFrame?
    private var copiedUntil = Date.distantPast

    var currentHex: String? { frameData?.hex }

    init(frame: NSRect, controller: LoupeController) {
        self.controller = controller
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func present(_ frame: LoupeFrame) {
        frameData = frame
        needsDisplay = true
    }

    func flashCopied() {
        copiedUntil = Date().addingTimeInterval(0.9)
        needsDisplay = true
    }

    // MARK: Input

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            controller.copyHex()
            return
        }
        switch event.charactersIgnoringModifiers {
        case "+", "=":
            controller.adjustZoom(by: +1)
        case "-", "_":
            controller.adjustZoom(by: -1)
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
            controller.copyHex()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        controller.copyHex()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let diameter = LoupeController.diameter
        let circle = NSRect(x: 0, y: 0, width: diameter, height: diameter)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Magnified pixels, clipped to the circle.
        context.saveGState()
        NSBezierPath(ovalIn: circle).addClip()
        NSColor(white: 0.12, alpha: 1).setFill()
        circle.fill()

        if let frame = frameData {
            let zoom = frame.zoom
            let dest = CGRect(x: (frame.clamped.minX - frame.desired.minX) * zoom,
                              y: (frame.clamped.minY - frame.desired.minY) * zoom,
                              width: frame.clamped.width * zoom,
                              height: frame.clamped.height * zoom)
            context.saveGState()
            context.translateBy(x: dest.minX, y: dest.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .none
            context.draw(frame.image, in: CGRect(origin: .zero, size: dest.size))
            context.restoreGState()

            drawGridIfNeeded(frame: frame, dest: dest)
            drawCenterPixel(frame: frame)
        }
        context.restoreGState()

        // Ring.
        NSColor.black.withAlphaComponent(0.55).setStroke()
        let outer = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
        outer.lineWidth = 1
        outer.stroke()
        NSColor.white.withAlphaComponent(0.92).setStroke()
        let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 1.5, dy: 1.5))
        ring.lineWidth = 2
        ring.stroke()

        drawLabel()
    }

    private func drawGridIfNeeded(frame: LoupeFrame, dest: CGRect) {
        let step = frame.zoom / frame.scale // view points per device pixel
        guard step >= 6 else { return }
        let path = NSBezierPath()
        path.lineWidth = 0.5
        var x = dest.minX
        while x <= dest.maxX + 0.01 {
            path.move(to: NSPoint(x: x, y: dest.minY))
            path.line(to: NSPoint(x: x, y: dest.maxY))
            x += step
        }
        var y = dest.minY
        while y <= dest.maxY + 0.01 {
            path.move(to: NSPoint(x: dest.minX, y: y))
            path.line(to: NSPoint(x: dest.maxX, y: y))
            y += step
        }
        NSColor.black.withAlphaComponent(0.22).setStroke()
        path.stroke()
    }

    private func drawCenterPixel(frame: LoupeFrame) {
        let pixelSide = 1 / frame.scale
        let sx = frame.clamped.minX
            + floor((frame.cursor.x - frame.clamped.minX) * frame.scale) / frame.scale
        let sy = frame.clamped.minY
            + floor((frame.cursor.y - frame.clamped.minY) * frame.scale) / frame.scale
        let rect = NSRect(x: (sx - frame.desired.minX) * frame.zoom,
                          y: (sy - frame.desired.minY) * frame.zoom,
                          width: pixelSide * frame.zoom,
                          height: pixelSide * frame.zoom)

        let outerBox = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        outerBox.lineWidth = 2
        NSColor.black.withAlphaComponent(0.7).setStroke()
        outerBox.stroke()
        let innerBox = NSBezierPath(rect: rect)
        innerBox.lineWidth = 1.2
        NSColor.white.setStroke()
        innerBox.stroke()
    }

    private func drawLabel() {
        let diameter = LoupeController.diameter
        let copied = Date() < copiedUntil
        let text: String
        if copied {
            text = "Copied"
        } else if let frame = frameData {
            text = "\(frame.hex)  ·  \(Int(frame.zoom))×"
        } else {
            text = "…"
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: copied ? NSColor.systemGreen : NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let box = NSRect(x: (diameter - size.width - 18) / 2,
                         y: diameter + 6,
                         width: size.width + 18,
                         height: size.height + 8)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        string.draw(at: NSPoint(x: box.minX + 9, y: box.minY + 4))
    }
}
