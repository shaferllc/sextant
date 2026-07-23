import AppKit
import ScreenCaptureKit

/// Pins a still of every display on top of the live screen.
///
/// Menus, tooltips, drag states and hover effects vanish the moment you reach
/// for a measuring tool. Freeze first and they hold still: the crosshair, the
/// ruler and the loupe all keep working, and the loupe reads its pixels out of
/// the frozen bitmap instead of the live screen, so it stays exact.
@MainActor
final class FreezeController: NSObject, ObservableObject {
    /// A captured display: pixels, plus what one point is worth in them.
    struct Frozen {
        let image: CGImage
        let scale: CGFloat
    }

    @Published var isActive = false {
        didSet {
            guard oldValue != isActive, !suppressSideEffects else { return }
            if isActive {
                Task { await activate() }
            } else {
                deactivate()
            }
        }
    }

    /// Fired when the still windows appear or disappear.
    var onWindowsChanged: (() -> Void)?

    private var windows: [NSWindow] = []
    private var frames: [CGDirectDisplayID: Frozen] = [:]
    private var suppressSideEffects = false

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// The still for a display, if the screen is currently frozen.
    func frozen(displayID: CGDirectDisplayID) -> Frozen? {
        isActive ? frames[displayID] : nil
    }

    // MARK: - Lifecycle

    private func setActive(_ value: Bool) {
        suppressSideEffects = true
        isActive = value
        suppressSideEffects = false
    }

    private func activate() async {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            setActive(false)
            PermissionExplainer.shared.show { [weak self] in
                self?.isActive = true
            }
            return
        }

        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else {
            setActive(false)
            return
        }

        let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        let ourWindows = content.windows.filter { $0.owningApplication?.processID == pid }

        var captured: [CGDirectDisplayID: Frozen] = [:]
        var newWindows: [NSWindow] = []

        for screen in NSScreen.screens {
            let displayID = Self.displayID(of: screen)
            guard let display = content.displays.first(where: { $0.displayID == displayID })
            else { continue }

            let scale = screen.backingScaleFactor
            let filter = SCContentFilter(display: display, excludingWindows: ourWindows)
            let config = SCStreamConfiguration()
            config.width = Int((CGFloat(display.width) * scale).rounded())
            config.height = Int((CGFloat(display.height) * scale).rounded())
            config.showsCursor = false

            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config) else { continue }

            captured[displayID] = Frozen(image: image, scale: scale)
            newWindows.append(Self.makeWindow(for: screen, image: image, controller: self))
        }

        guard !captured.isEmpty else {
            setActive(false)
            return
        }
        // The toggle may have been flipped back off while we were capturing.
        guard isActive else { return }

        frames = captured
        windows = newWindows
        for window in windows { window.orderFrontRegardless() }
        onWindowsChanged?()
    }

    private func deactivate() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        frames.removeAll()
        onWindowsChanged?()
    }

    /// Clicking the still thaws it — the frozen screen is not interactive, and
    /// the click that proves you forgot should be the one that fixes it.
    fileprivate func thaw() {
        if isActive { isActive = false }
    }

    @objc private func screensChanged(_ note: Notification) {
        // Display geometry changed under the still; it can only be wrong now.
        if isActive { isActive = false }
    }

    // MARK: - Helpers

    private static func makeWindow(for screen: NSScreen, image: CGImage,
                                   controller: FreezeController) -> NSWindow {
        let window = FreezeWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                     .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.contentView = FreezeView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            image: image, controller: controller)
        window.setFrame(screen.frame, display: true)
        return window
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - Window & view

private final class FreezeWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FreezeView: NSView {
    private let image: CGImage
    private unowned let controller: FreezeController

    init(frame: NSRect, image: CGImage, controller: FreezeController) {
        self.image = image
        self.controller = controller
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        controller.thaw()
    }

    override func rightMouseDown(with event: NSEvent) {
        controller.thaw()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.draw(image, in: bounds)
    }
}
