import AppKit
import SwiftUI

/// Friendly explainer shown when the loupe cannot capture the screen.
@MainActor
final class PermissionExplainer {
    static let shared = PermissionExplainer()

    private var window: NSWindow?
    private var retryAction: (() -> Void)?

    private init() {}

    func show(retry: @escaping () -> Void) {
        retryAction = retry
        if window == nil {
            let view = PermissionView(
                openSettings: {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                    NSWorkspace.shared.open(url)
                },
                tryAgain: { [weak self] in self?.tryAgain() }
            )
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable]
            window.title = "Sextant"
            window.isReleasedWhenClosed = false
            window.level = .floating
            self.window = window
        }
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Returns true if access is now granted (and kicks off the retry).
    func tryAgain() {
        guard CGPreflightScreenCaptureAccess() else {
            NSSound.beep()
            return
        }
        window?.orderOut(nil)
        retryAction?()
        retryAction = nil
    }
}

private struct PermissionView: View {
    let openSettings: () -> Void
    let tryAgain: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("The loupe needs Screen Recording access")
                .font(.headline)
            Text("Sextant magnifies the pixels around your pointer, and macOS treats reading those pixels as screen recording. Grant access to Sextant under Privacy & Security → Screen & System Audio Recording, then come back here.\n\nThe crosshair works without any permissions. If macOS doesn't pick up the change, quit and reopen Sextant.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Open System Settings", action: openSettings)
                    .keyboardShortcut(.defaultAction)
                Button("Try Again", action: tryAgain)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
