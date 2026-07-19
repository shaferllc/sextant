import AppKit

extension Notification.Name {
    static let sextantSettingsChanged = Notification.Name("SextantSettingsChanged")
}

/// User preferences, persisted as JSON under ~/Library/Application Support/Sextant/.
@MainActor
final class SettingsStore: ObservableObject {
    struct RGBA: Codable, Equatable {
        var r: Double
        var g: Double
        var b: Double
        var a: Double
    }

    private struct Snapshot: Codable {
        var crosshairColor: RGBA
        var crosshairThickness: Double
        var showCoordinates: Bool
        var defaultZoom: Double
    }

    @Published var crosshairColor = RGBA(r: 1.00, g: 0.27, b: 0.23, a: 0.90) {
        didSet { persist() }
    }
    @Published var crosshairThickness: Double = 1.0 {
        didSet { persist() }
    }
    @Published var showCoordinates = true {
        didSet { persist() }
    }
    @Published var defaultZoom: Double = 8 {
        didSet { persist() }
    }

    var crosshairNSColor: NSColor {
        NSColor(srgbRed: crosshairColor.r, green: crosshairColor.g,
                blue: crosshairColor.b, alpha: crosshairColor.a)
    }

    private var loading = false

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Sextant", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        loading = true
        crosshairColor = snap.crosshairColor
        crosshairThickness = snap.crosshairThickness
        showCoordinates = snap.showCoordinates
        defaultZoom = snap.defaultZoom
        loading = false
    }

    private func persist() {
        guard !loading else { return }
        let snap = Snapshot(crosshairColor: crosshairColor,
                            crosshairThickness: crosshairThickness,
                            showCoordinates: showCoordinates,
                            defaultZoom: defaultZoom)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snap) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
        NotificationCenter.default.post(name: .sextantSettingsChanged, object: nil)
    }
}
