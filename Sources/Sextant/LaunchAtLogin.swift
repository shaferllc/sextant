import Foundation
import ServiceManagement

/// Thin wrapper over SMAppService so the setting reads like a boolean.
///
/// Registration only sticks for a real bundled app — running the binary
/// straight out of `.build` will throw, which we swallow: the toggle simply
/// won't take until Sextant.app is installed.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Sextant: launch at login \(enabled ? "register" : "unregister") failed: \(error)")
        }
    }
}
