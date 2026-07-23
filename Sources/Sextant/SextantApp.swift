import SwiftUI

@main
struct SextantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Sextant", systemImage: "scope") {
            MenuContent(model: AppModel.shared)
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
    @ObservedObject var model: AppModel
    @ObservedObject private var crosshair: CrosshairController
    @ObservedObject private var loupe: LoupeController
    @ObservedObject private var measure: MeasureController
    @ObservedObject private var freeze: FreezeController
    @ObservedObject private var guides: GuideStore
    @ObservedObject private var settings: SettingsStore

    init(model: AppModel) {
        self.model = model
        self.crosshair = model.crosshair
        self.loupe = model.loupe
        self.measure = model.measure
        self.freeze = model.freeze
        self.guides = model.guides
        self.settings = model.settings
    }

    /// Menu items carry their shortcut as text — the bindings are Carbon
    /// hotkeys, which SwiftUI's `keyboardShortcut` knows nothing about.
    private func label(_ title: String, _ action: HotKeyAction) -> String {
        "\(title) \u{2003}\(settings.shortcut(for: action))"
    }

    var body: some View {
        Toggle(label("Crosshair", .crosshair), isOn: $crosshair.isActive)
        Toggle(label("Loupe", .loupe), isOn: $loupe.isActive)
        Toggle(label("Measure", .measure), isOn: $measure.isActive)
        Toggle(label("Layout grid", .grid), isOn: $crosshair.showGrid)
        Toggle(label("Freeze screen", .freeze), isOn: $freeze.isActive)

        Divider()

        Button(label("Drop guides at pointer", .dropGuide)) {
            model.guides.dropAtPointer()
        }
        Button(label("Clear guides", .clearGuides)) {
            model.guides.clear()
        }
        .disabled(guides.isEmpty)
        Button(label("Palette…", .palette)) {
            PalettePanel.shared.show(history: model.history, settings: settings)
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }

        Divider()

        Button("Quit Sextant") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
