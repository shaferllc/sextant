import AppKit

/// Wires the pieces together: settings, the two controllers, and hotkeys.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings: SettingsStore
    let crosshair: CrosshairController
    let loupe: LoupeController

    private init() {
        let settings = SettingsStore()
        self.settings = settings
        self.crosshair = CrosshairController(settings: settings)
        self.loupe = LoupeController(settings: settings)
    }

    func start() {
        // When crosshair overlays appear/disappear, the loupe must refresh its
        // window-exclusion list so hairlines never show up inside the magnifier.
        crosshair.onWindowsChanged = { [weak self] in
            self?.loupe.noteWindowsChanged()
        }
        HotKeyCenter.shared.onTrigger = { [weak self] id in
            guard let self else { return }
            switch id {
            case .crosshair: self.crosshair.isActive.toggle()
            case .loupe: self.loupe.isActive.toggle()
            }
        }
        HotKeyCenter.shared.registerDefaults()
    }
}
