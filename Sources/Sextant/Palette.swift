import AppKit
import SwiftUI

/// One colour the loupe has copied, kept so you can build a palette by
/// wandering around the screen instead of copying, pasting, copying, pasting.
struct Swatch: Identifiable, Codable, Equatable {
    var id = UUID()
    var color: SampledColor
}

/// The last few colours picked, newest first. Persisted next to settings.
@MainActor
final class ColorHistory: ObservableObject {
    static let limit = 24

    @Published private(set) var swatches: [Swatch] = [] {
        didSet { persist() }
    }

    private var loading = false
    private static var fileURL: URL {
        SettingsStore.supportDirectory.appendingPathComponent("palette.json")
    }

    init() {
        load()
    }

    func add(_ color: SampledColor) {
        // Picking the same colour twice in a row shouldn't fill the strip.
        if let first = swatches.first, first.color == color { return }
        swatches.insert(Swatch(color: color), at: 0)
        if swatches.count > Self.limit {
            swatches.removeLast(swatches.count - Self.limit)
        }
    }

    func remove(_ swatch: Swatch) {
        swatches.removeAll { $0.id == swatch.id }
    }

    func clear() {
        swatches.removeAll()
    }

    /// The two most recent colours, for a running contrast check.
    var pair: (SampledColor, SampledColor)? {
        guard swatches.count >= 2 else { return nil }
        return (swatches[0].color, swatches[1].color)
    }

    // MARK: Export

    func export(as format: ColorFormat) -> String {
        swatches.map { format.string(for: $0.color) }.joined(separator: "\n")
    }

    func exportCSSVariables() -> String {
        let lines = swatches.enumerated().map { index, swatch in
            "  --sextant-\(index + 1): \(swatch.color.hex);"
        }
        return ":root {\n" + lines.joined(separator: "\n") + "\n}"
    }

    func exportSwift() -> String {
        let lines = swatches.enumerated().map { index, swatch in
            "    static let sextant\(index + 1) = "
                + ColorFormat.swiftUI.string(for: swatch.color)
        }
        return "extension Color {\n" + lines.joined(separator: "\n") + "\n}"
    }

    func exportJSON() -> String {
        let entries = swatches.map { swatch -> String in
            let (h, s, l) = swatch.color.hsl
            return String(
                format: """
                  {
                    "hex": "%@",
                    "rgb": [%d, %d, %d],
                    "hsl": [%.0f, %.2f, %.2f]
                  }
                """,
                swatch.color.hex, swatch.color.r8, swatch.color.g8, swatch.color.b8, h, s, l)
        }
        return "[\n" + entries.joined(separator: ",\n") + "\n]"
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let stored = try? JSONDecoder().decode([Swatch].self, from: data)
        else { return }
        loading = true
        swatches = stored
        loading = false
    }

    private func persist() {
        guard !loading else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(swatches) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}

/// The floating palette window.
@MainActor
final class PalettePanel {
    static let shared = PalettePanel()

    private var window: NSWindow?

    private init() {}

    func toggle(history: ColorHistory, settings: SettingsStore) {
        if let window, window.isVisible {
            window.orderOut(nil)
        } else {
            show(history: history, settings: settings)
        }
    }

    func show(history: ColorHistory, settings: SettingsStore) {
        if window == nil {
            let hosting = NSHostingController(
                rootView: PaletteView(history: history, settings: settings))
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .resizable]
            window.title = "Palette"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.setContentSize(NSSize(width: 340, height: 460))
            self.window = window
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct PaletteView: View {
    @ObservedObject var history: ColorHistory
    @ObservedObject var settings: SettingsStore
    @State private var copied: String?

    private let columns = [GridItem(.adaptive(minimum: 68), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if history.swatches.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Colours you copy from the loupe land here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(history.swatches) { swatch in
                            SwatchTile(swatch: swatch, format: settings.colorFormat) {
                                copy(settings.colorFormat.string(for: swatch.color))
                            } onDelete: {
                                history.remove(swatch)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                if let pair = history.pair {
                    let ratio = SampledColor.contrastRatio(pair.0, pair.1)
                    HStack(spacing: 8) {
                        Text("Latest two")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.2f:1", ratio))
                            .font(.system(.caption, design: .monospaced))
                        Text(SampledColor.wcagGrade(ratio))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ratio >= 4.5 ? Color.green.opacity(0.22)
                                                     : Color.orange.opacity(0.22))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Menu("Export") {
                    Button("As \(settings.colorFormat.title)") {
                        copy(history.export(as: settings.colorFormat))
                    }
                    Button("CSS variables") { copy(history.exportCSSVariables()) }
                    Button("SwiftUI extension") { copy(history.exportSwift()) }
                    Button("JSON") { copy(history.exportJSON()) }
                }
                .disabled(history.swatches.isEmpty)
                .frame(width: 100)

                Spacer()

                Button("Clear", role: .destructive) { history.clear() }
                    .disabled(history.swatches.isEmpty)
            }

            if let copied {
                Text(copied)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(minWidth: 300, minHeight: 360)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = "Copied \(text.split(separator: "\n").count) line(s) to the clipboard"
    }
}

private struct SwatchTile: View {
    let swatch: Swatch
    let format: ColorFormat
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onCopy) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(swatch.color.nsColor))
                    .frame(height: 40)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.primary.opacity(0.16), lineWidth: 1))
                Text(swatch.color.hex)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help("Copy as \(format.title)")
        .contextMenu {
            Button("Copy \(format.title)", action: onCopy)
            Button("Remove", role: .destructive, action: onDelete)
        }
    }
}
