import AppKit
import Carbon.HIToolbox
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
    /// The colour under the pointer, averaged over the sample square.
    let color: SampledColor
}

/// A circular magnifier that floats beside the pointer, refreshed ~30 fps via
/// ScreenCaptureKit screenshots of a small region around the cursor. When the
/// screen is frozen it reads from the frozen bitmap instead, which is both
/// exact and free.
@MainActor
final class LoupeController: NSObject, ObservableObject {
    static let diameter: CGFloat = 176
    static let windowWidth: CGFloat = 248
    /// Room under the circle for the colour line and the contrast line.
    static let labelStrip: CGFloat = 62
    static let zoomSteps: [CGFloat] = [2, 4, 8, 16, 32]
    static let sampleSizes: [Int] = [1, 3, 5, 11]

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

    /// A colour parked for comparison — the loupe then shows the live WCAG
    /// contrast ratio against whatever is under the pointer.
    @Published private(set) var reference: SampledColor?

    private let settings: SettingsStore
    private let freeze: FreezeController
    private let history: ColorHistory
    private var suppressSideEffects = false
    private var window: LoupeWindow?
    private var loupeView: LoupeView?
    private var timer: Timer?
    private var content: SCShareableContent?
    private var contentDirty = true
    private var cachedFilter: SCContentFilter?
    private var cachedFilterDisplayID: CGDirectDisplayID = 0
    private var inFlight = false

    init(settings: SettingsStore, freeze: FreezeController, history: ColorHistory) {
        self.settings = settings
        self.freeze = freeze
        self.history = history
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

        let size = NSSize(width: Self.windowWidth, height: Self.diameter + Self.labelStrip)
        let window = LoupeWindow(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        let view = LoupeView(frame: NSRect(origin: .zero, size: size), controller: self)
        window.contentView = view
        self.window = window
        self.loupeView = view

        positionWindow()
        window.orderFrontRegardless()
        // Take key focus so the one-key controls work while the loupe is up.
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

    /// Cycles the sample square: 1×1 exact, or 3/5/11 averaged like a
    /// designer's eyedropper, which is what you want on anti-aliased text.
    func adjustSample(by delta: Int) {
        let sizes = Self.sampleSizes
        let index = sizes.firstIndex(of: settings.sampleSize) ?? 0
        settings.sampleSize = sizes[min(max(index + delta, 0), sizes.count - 1)]
        loupeView?.needsDisplay = true
    }

    var sampleSize: Int { settings.sampleSize }
    var format: ColorFormat { settings.colorFormat }

    func cycleFormat() {
        settings.colorFormat = settings.colorFormat.next
        loupeView?.needsDisplay = true
    }

    /// Parks (or releases) the colour under the pointer as the contrast pair.
    func toggleReference() {
        if reference != nil {
            reference = nil
        } else {
            reference = loupeView?.currentColor
        }
        loupeView?.needsDisplay = true
    }

    /// Moves the pointer by exact device pixels, so you can land on the one you
    /// mean instead of fighting the trackpad.
    func nudge(dx: CGFloat, dy: CGFloat, coarse: Bool) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(pointer, $0.frame, false)
        }) ?? NSScreen.main else { return }
        let step = (coarse ? 10 : 1) / screen.backingScaleFactor
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let target = CGPoint(x: pointer.x + dx * step,
                             y: primaryHeight - (pointer.y + dy * step))
        CGWarpMouseCursorPosition(target)
    }

    func copyColor() {
        guard let color = loupeView?.currentColor else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(settings.colorFormat.string(for: color), forType: .string)
        history.add(color)
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

    /// The geometry shared by the live and frozen paths.
    private struct Region {
        let desired: CGRect
        let clamped: CGRect
        let scale: CGFloat
        let cursor: CGPoint
    }

    private func region(for screen: NSScreen, displayPointSize: CGSize) -> Region? {
        let pointer = NSEvent.mouseLocation
        let scale = screen.backingScaleFactor
        let side = Self.diameter / zoom
        let localX = pointer.x - screen.frame.minX
        let localYTop = screen.frame.maxY - pointer.y
        var desired = CGRect(x: localX - side / 2, y: localYTop - side / 2,
                             width: side, height: side)
        desired.origin.x = floor(desired.origin.x * scale) / scale
        desired.origin.y = floor(desired.origin.y * scale) / scale

        let displayBounds = CGRect(origin: .zero, size: displayPointSize)
        var clamped = desired.intersection(displayBounds)
        guard !clamped.isEmpty else { return nil }
        // Align to the pixel grid so magnified pixels stay crisp.
        let minX = floor(clamped.minX * scale) / scale
        let minY = floor(clamped.minY * scale) / scale
        let maxX = ceil(clamped.maxX * scale) / scale
        let maxY = ceil(clamped.maxY * scale) / scale
        clamped = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        return Region(desired: desired, clamped: clamped, scale: scale,
                      cursor: CGPoint(x: localX, y: localYTop))
    }

    private func captureFrame() async {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(pointer, $0.frame, false)
        }) ?? NSScreen.main else { return }
        let displayID = FreezeController.displayID(of: screen)

        // Frozen: crop the still we already hold. No capture, no permission
        // round-trip, and the pixels can't shift under the magnifier.
        if let frozen = freeze.frozen(displayID: displayID) {
            let pointSize = CGSize(width: CGFloat(frozen.image.width) / frozen.scale,
                                   height: CGFloat(frozen.image.height) / frozen.scale)
            guard let region = region(for: screen, displayPointSize: pointSize) else { return }
            let pixels = CGRect(x: (region.clamped.minX * frozen.scale).rounded(),
                                y: (region.clamped.minY * frozen.scale).rounded(),
                                width: max(1, (region.clamped.width * frozen.scale).rounded()),
                                height: max(1, (region.clamped.height * frozen.scale).rounded()))
            guard let cropped = frozen.image.cropping(to: pixels) else { return }
            present(image: cropped, region: region)
            return
        }

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

        let displayPointSize = CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
        guard let region = region(for: screen, displayPointSize: displayPointSize) else { return }

        let config = SCStreamConfiguration()
        config.sourceRect = region.clamped
        config.width = max(1, Int((region.clamped.width * region.scale).rounded()))
        config.height = max(1, Int((region.clamped.height * region.scale).rounded()))
        config.showsCursor = false

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            guard isActive else { return }
            present(image: image, region: region)
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

    private func present(image: CGImage, region: Region) {
        let color = Self.color(of: image, at: region.cursor, in: region.clamped,
                               sampleSize: settings.sampleSize)
        loupeView?.present(LoupeFrame(image: image, desired: region.desired,
                                      clamped: region.clamped, scale: region.scale,
                                      zoom: zoom, cursor: region.cursor, color: color))
    }

    // MARK: - Sampling

    /// Reads the pixel under the pointer, averaged over a `sampleSize` square.
    private static func color(of image: CGImage, at cursor: CGPoint, in clamped: CGRect,
                              sampleSize: Int) -> SampledColor {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, clamped.width > 0, clamped.height > 0 else {
            return .black
        }
        let side = max(1, sampleSize)
        let half = side / 2
        let fx = (cursor.x - clamped.minX) / clamped.width
        let fy = (cursor.y - clamped.minY) / clamped.height
        let px = min(max(Int(fx * CGFloat(width)), 0), width - 1)
        let py = min(max(Int(fy * CGFloat(height)), 0), height - 1)

        var buffer = [UInt8](repeating: 0, count: side * side * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(data: &buffer, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: info) else { return .black }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: CGFloat(half - px),
                                       y: CGFloat(half) - CGFloat(height - 1 - py),
                                       width: CGFloat(width),
                                       height: CGFloat(height)))

        var r = 0, g = 0, b = 0, counted = 0
        for index in stride(from: 0, to: buffer.count, by: 4) where buffer[index + 3] > 0 {
            r += Int(buffer[index])
            g += Int(buffer[index + 1])
            b += Int(buffer[index + 2])
            counted += 1
        }
        guard counted > 0 else { return .black }
        return SampledColor(r8: r / counted, g8: g / counted, b8: b / counted)
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

    /// Horizontal inset of the circle inside the (wider) window.
    private var circleX: CGFloat { (LoupeController.windowWidth - LoupeController.diameter) / 2 }

    var currentColor: SampledColor? { frameData?.color }

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
            controller.copyColor()
            return
        }

        let coarse = event.modifierFlags.contains(.shift)
        switch Int(event.keyCode) {
        case kVK_LeftArrow:
            controller.nudge(dx: -1, dy: 0, coarse: coarse)
            return
        case kVK_RightArrow:
            controller.nudge(dx: 1, dy: 0, coarse: coarse)
            return
        case kVK_UpArrow:
            controller.nudge(dx: 0, dy: 1, coarse: coarse)
            return
        case kVK_DownArrow:
            controller.nudge(dx: 0, dy: -1, coarse: coarse)
            return
        case kVK_Escape:
            controller.dismiss()
            return
        default:
            break
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "+", "=":
            controller.adjustZoom(by: +1)
        case "-", "_":
            controller.adjustZoom(by: -1)
        case "[":
            controller.adjustSample(by: -1)
        case "]":
            controller.adjustSample(by: +1)
        case "f":
            controller.cycleFormat()
        case "x":
            controller.toggleReference()
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            controller.copyColor()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        controller.copyColor()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let diameter = LoupeController.diameter
        let circle = NSRect(x: circleX, y: 0, width: diameter, height: diameter)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Magnified pixels, clipped to the circle.
        context.saveGState()
        NSBezierPath(ovalIn: circle).addClip()
        NSColor(white: 0.12, alpha: 1).setFill()
        circle.fill()

        if let frame = frameData {
            context.saveGState()
            context.translateBy(x: circleX, y: 0)
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
            context.restoreGState()
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
        drawContrastLine()
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

    /// Outlines the sampled square — one pixel, or the whole averaged block.
    private func drawCenterPixel(frame: LoupeFrame) {
        let pixelSide = 1 / frame.scale
        let sample = CGFloat(max(1, controller.sampleSize))
        let half = (sample - 1) / 2
        let sx = frame.clamped.minX
            + floor((frame.cursor.x - frame.clamped.minX) * frame.scale) / frame.scale
        let sy = frame.clamped.minY
            + floor((frame.cursor.y - frame.clamped.minY) * frame.scale) / frame.scale
        let rect = NSRect(x: (sx - half * pixelSide - frame.desired.minX) * frame.zoom,
                          y: (sy - half * pixelSide - frame.desired.minY) * frame.zoom,
                          width: pixelSide * sample * frame.zoom,
                          height: pixelSide * sample * frame.zoom)

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
        let copied = Date() < copiedUntil
        let text: String
        if copied {
            text = "Copied as \(controller.format.tag)"
        } else if let frame = frameData {
            let sample = controller.sampleSize
            let sampleTag = sample > 1 ? "  ·  \(sample)px" : ""
            text = "\(frame.color.hex)  ·  \(controller.format.tag)  ·  \(Int(frame.zoom))×\(sampleTag)"
        } else {
            text = "…"
        }
        draw(badge: text, y: LoupeController.diameter + 6,
             color: copied ? .systemGreen : .white, size: 12)
    }

    private func drawContrastLine() {
        guard let reference = controller.reference, let color = frameData?.color else { return }
        let ratio = SampledColor.contrastRatio(reference, color)
        let text = String(format: "%@ ⇄ %@  %.2f:1  %@",
                          reference.hex, color.hex, ratio, SampledColor.wcagGrade(ratio))
        let pass = ratio >= 4.5
        draw(badge: text, y: LoupeController.diameter + 32,
             color: pass ? .systemGreen : .systemOrange, size: 11)
    }

    private func draw(badge text: String, y: CGFloat, color: NSColor, size: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let textSize = string.size()
        let box = NSRect(x: (bounds.width - textSize.width - 16) / 2,
                         y: y,
                         width: textSize.width + 16,
                         height: textSize.height + 6)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        string.draw(at: NSPoint(x: box.minX + 8, y: box.minY + 3))
    }
}
