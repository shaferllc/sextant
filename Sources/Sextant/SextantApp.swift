import SwiftUI

@main
struct SextantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Sextant", systemImage: "scope") {
            MenuContent(crosshair: AppModel.shared.crosshair,
                        loupe: AppModel.shared.loupe)
        }
        Settings {
            SettingsView(settings: AppModel.shared.settings)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }
}

struct MenuContent: View {
    @ObservedObject var crosshair: CrosshairController
    @ObservedObject var loupe: LoupeController

    var body: some View {
        Toggle("Crosshair \u{2003}⌥⌘X", isOn: $crosshair.isActive)
        Toggle("Loupe \u{2003}⌥⌘L", isOn: $loupe.isActive)
        Divider()
        SettingsLink {
            Text("Settings…")
        }
        Divider()
        Button("Quit Sextant") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
