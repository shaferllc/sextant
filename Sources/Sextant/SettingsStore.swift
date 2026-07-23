import AppKit

extension Notification.Name {
    static let sextantSettingsChanged = Notification.Name("SextantSettingsChanged")
}

/// User preferences, persisted as JSON under ~/Library/Application Support/Sextant/.
///
/// Every field is optional in the on-disk snapshot, so a settings file written
/// by an older build still loads: missing keys keep their defaults.
@MainActor
final class SettingsStore: ObservableObject {
    struct RGBA: Codable, Equatable {
        var r: Double
        var g: Double
        var b: Double
        var a: Double
    }

    private struct Snapshot: Codable {
        var crosshairColor: RGBA?
        var crosshairThickness: Double?
        var crosshairDashed: Bool?
        var crosshairGap: Double?
        var showCoordinates: Bool?
        var snapToGuides: Bool?
        var defaultZoom: Double?
        var colorFormat: ColorFormat?
        var sampleSize: Int?
        var gridColumns: Int?
        var gridGutter: Double?
        var gridMargin: Double?
        var gridBaseline: Double?
        var gridColor: RGBA?
        var launchAtLogin: Bool?
        var hotKeys: [String: KeyCombo]?
    }

    // MARK: Crosshair

    @Published var crosshairColor = RGBA(r: 1.00, g: 0.27, b: 0.23, a: 0.90) {
        didSet { persist() }
    }
    @Published var crosshairThickness: Double = 1.0 {
        didSet { persist() }
    }
    /// Draw the hairlines dashed instead of solid — easier to read over busy UI.
    @Published var crosshairDashed = false {
        didSet { persist() }
    }
    /// Radius of the gap left open around the pointer, in points (0 = none).
    @Published var crosshairGap: Double = 0 {
        didSet { persist() }
    }
    @Published var showCoordinates = true {
        didSet { persist() }
    }
    /// Pull the hairlines onto a nearby guide when they come within a few points.
    @Published var snapToGuides = true {
        didSet { persist() }
    }

    // MARK: Loupe

    @Published var defaultZoom: Double = 8 {
        didSet { persist() }
    }
    @Published var colorFormat: ColorFormat = .hex {
        didSet { persist() }
    }
    /// Width, in device pixels, of the square averaged under the pointer.
    @Published var sampleSize: Int = 1 {
        didSet { persist() }
    }

    // MARK: Grid

    @Published var gridColumns: Int = 12 {
        didSet { persist() }
    }
    @Published var gridGutter: Double = 24 {
        didSet { persist() }
    }
    @Published var gridMargin: Double = 64 {
        didSet { persist() }
    }
    /// Baseline row height in points (0 turns the horizontal rhythm off).
    @Published var gridBaseline: Double = 8 {
        didSet { persist() }
    }
    @Published var gridColor = RGBA(r: 0.25, g: 0.62, b: 1.00, a: 0.35) {
        didSet { persist() }
    }

    // MARK: General

    @Published var launchAtLogin = false {
        didSet {
            guard oldValue != launchAtLogin else { return }
            persist()
            guard !loading else { return }
            LaunchAtLogin.set(launchAtLogin)
        }
    }

    @Published var hotKeys: [HotKeyAction: KeyCombo] = SettingsStore.defaultHotKeys {
        didSet {
            persist()
            HotKeyCenter.shared.apply(hotKeys)
        }
    }

    static var defaultHotKeys: [HotKeyAction: KeyCombo] {
        var map: [HotKeyAction: KeyCombo] = [:]
        for action in HotKeyAction.allCases { map[action] = action.defaultCombo }
        return map
    }

    func combo(for action: HotKeyAction) -> KeyCombo {
        hotKeys[action] ?? action.defaultCombo
    }

    /// The shortcut as macOS prints it, for menus and settings labels.
    func shortcut(for action: HotKeyAction) -> String {
        combo(for: action).display
    }

    // MARK: Derived colours

    var crosshairNSColor: NSColor {
        NSColor(srgbRed: crosshairColor.r, green: crosshairColor.g,
                blue: crosshairColor.b, alpha: crosshairColor.a)
    }

    var gridNSColor: NSColor {
        NSColor(srgbRed: gridColor.r, green: gridColor.g,
                blue: gridColor.b, alpha: gridColor.a)
    }

    private var loading = false

    private static var fileURL: URL {
        SettingsStore.supportDirectory.appendingPathComponent("settings.json")
    }

    /// ~/Library/Application Support/Sextant, created on first use.
    static var supportDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Sextant", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        loading = true
        crosshairColor = snap.crosshairColor ?? crosshairColor
        crosshairThickness = snap.crosshairThickness ?? crosshairThickness
        crosshairDashed = snap.crosshairDashed ?? crosshairDashed
        crosshairGap = snap.crosshairGap ?? crosshairGap
        showCoordinates = snap.showCoordinates ?? showCoordinates
        snapToGuides = snap.snapToGuides ?? snapToGuides
        defaultZoom = snap.defaultZoom ?? defaultZoom
        colorFormat = snap.colorFormat ?? colorFormat
        sampleSize = snap.sampleSize ?? sampleSize
        gridColumns = snap.gridColumns ?? gridColumns
        gridGutter = snap.gridGutter ?? gridGutter
        gridMargin = snap.gridMargin ?? gridMargin
        gridBaseline = snap.gridBaseline ?? gridBaseline
        gridColor = snap.gridColor ?? gridColor
        launchAtLogin = snap.launchAtLogin ?? launchAtLogin
        if let stored = snap.hotKeys {
            var map = Self.defaultHotKeys
            for (key, combo) in stored {
                if let action = HotKeyAction(rawValue: key) { map[action] = combo }
            }
            hotKeys = map
        }
        loading = false
    }

    private func persist() {
        guard !loading else { return }
        var keys: [String: KeyCombo] = [:]
        for (action, combo) in hotKeys { keys[action.rawValue] = combo }
        let snap = Snapshot(crosshairColor: crosshairColor,
                            crosshairThickness: crosshairThickness,
                            crosshairDashed: crosshairDashed,
                            crosshairGap: crosshairGap,
                            showCoordinates: showCoordinates,
                            snapToGuides: snapToGuides,
                            defaultZoom: defaultZoom,
                            colorFormat: colorFormat,
                            sampleSize: sampleSize,
                            gridColumns: gridColumns,
                            gridGutter: gridGutter,
                            gridMargin: gridMargin,
                            gridBaseline: gridBaseline,
                            gridColor: gridColor,
                            launchAtLogin: launchAtLogin,
                            hotKeys: keys)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snap) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
        NotificationCenter.default.post(name: .sextantSettingsChanged, object: nil)
    }
}
