import AppKit

/// Wires the pieces together: settings, the instruments, and the hotkeys that
/// drive them.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings: SettingsStore
    let guides: GuideStore
    let history: ColorHistory
    let freeze: FreezeController
    let crosshair: CrosshairController
    let loupe: LoupeController
    let measure: MeasureController

    private init() {
        let settings = SettingsStore()
        let guides = GuideStore()
        let history = ColorHistory()
        let freeze = FreezeController()
        self.settings = settings
        self.guides = guides
        self.history = history
        self.freeze = freeze
        self.crosshair = CrosshairController(settings: settings, guides: guides)
        self.loupe = LoupeController(settings: settings, freeze: freeze, history: history)
        self.measure = MeasureController(settings: settings, guides: guides)
    }

    func start() {
        // Whenever any of our overlays appear or disappear, the loupe must
        // refresh its window-exclusion list so hairlines, marquees and stills
        // never show up inside the magnifier.
        let refreshLoupe: () -> Void = { [weak self] in self?.loupe.noteWindowsChanged() }
        crosshair.onWindowsChanged = refreshLoupe
        measure.onWindowsChanged = refreshLoupe
        freeze.onWindowsChanged = refreshLoupe

        guides.onChange = { [weak self] in self?.crosshair.guidesChanged() }
        // Guides loaded from disk should be on screen from the start.
        crosshair.guidesChanged()

        // Mirror whatever the login-items list actually says.
        settings.launchAtLogin = LaunchAtLogin.isEnabled

        HotKeyCenter.shared.onTrigger = { [weak self] action in
            self?.perform(action)
        }
        HotKeyCenter.shared.apply(settings.hotKeys)
    }

    func perform(_ action: HotKeyAction) {
        switch action {
        case .crosshair: crosshair.isActive.toggle()
        case .loupe: loupe.isActive.toggle()
        case .measure: measure.isActive.toggle()
        case .grid: crosshair.showGrid.toggle()
        case .freeze: freeze.isActive.toggle()
        case .dropGuide: guides.dropAtPointer()
        case .clearGuides: guides.clear()
        case .palette: PalettePanel.shared.toggle(history: history, settings: settings)
        }
    }
}
