import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        TabView {
            CrosshairSettings(settings: settings)
                .tabItem { Label("Crosshair", systemImage: "plus.viewfinder") }
            LoupeSettings(settings: settings)
                .tabItem { Label("Loupe", systemImage: "magnifyingglass") }
            GridSettings(settings: settings)
                .tabItem { Label("Grid", systemImage: "square.grid.3x3") }
            ShortcutSettings(settings: settings)
                .tabItem { Label("Shortcuts", systemImage: "command") }
            GeneralSettings(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 460)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Crosshair

private struct CrosshairSettings: View {
    @ObservedObject var settings: SettingsStore

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                let c = settings.crosshairColor
                return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
            },
            set: { newValue in
                guard let ns = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                settings.crosshairColor = SettingsStore.RGBA(
                    r: ns.redComponent, g: ns.greenComponent,
                    b: ns.blueComponent, a: ns.alphaComponent)
            }
        )
    }

    var body: some View {
        Form {
            Section("Hairlines") {
                ColorPicker("Color", selection: colorBinding, supportsOpacity: true)
                HStack {
                    Slider(value: $settings.crosshairThickness, in: 0.5...4, step: 0.5) {
                        Text("Thickness")
                    }
                    Text(String(format: "%.1f pt", settings.crosshairThickness))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
                Toggle("Dashed", isOn: $settings.crosshairDashed)
                HStack {
                    Slider(value: $settings.crosshairGap, in: 0...60, step: 2) {
                        Text("Gap at the pointer")
                    }
                    Text("\(Int(settings.crosshairGap)) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
                Toggle("Show pointer coordinates", isOn: $settings.showCoordinates)
            }
            Section("Guides") {
                Toggle("Snap the crosshair and ruler to guides", isOn: $settings.snapToGuides)
                Text("Guides are dropped at the pointer and stay put — across screens, across launches — until you clear them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Loupe

private struct LoupeSettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Magnifier") {
                Picker("Default zoom", selection: $settings.defaultZoom) {
                    ForEach([2.0, 4.0, 8.0, 16.0, 32.0], id: \.self) { zoom in
                        Text("\(Int(zoom))×").tag(zoom)
                    }
                }
                Picker("Sample size", selection: $settings.sampleSize) {
                    ForEach(LoupeController.sampleSizes, id: \.self) { size in
                        Text(size == 1 ? "1 px (exact)" : "\(size) × \(size) average").tag(size)
                    }
                }
            }
            Section("Colour") {
                Picker("Copy as", selection: $settings.colorFormat) {
                    ForEach(ColorFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                Text(ColorFormat.allCases
                    .first(where: { $0 == settings.colorFormat })?
                    .string(for: SampledColor(r8: 184, g8: 80, b8: 28)) ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Section("While the loupe is open") {
                KeyRow("+ / −", "Zoom in or out")
                KeyRow("[ / ]", "Smaller or larger sample square")
                KeyRow("F", "Cycle the copy format")
                KeyRow("X", "Park a colour, then read the live WCAG contrast")
                KeyRow("← ↑ → ↓", "Nudge the pointer a device pixel (⇧ for ten)")
                KeyRow("⌘C / click", "Copy the colour")
                KeyRow("esc", "Close the loupe")
            }
        }
        .formStyle(.grouped)
    }
}

private struct KeyRow: View {
    let keys: String
    let what: String

    init(_ keys: String, _ what: String) {
        self.keys = keys
        self.what = what
    }

    var body: some View {
        LabeledContent {
            Text(what)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        } label: {
            Text(keys).font(.system(.body, design: .monospaced))
        }
    }
}

// MARK: - Grid

private struct GridSettings: View {
    @ObservedObject var settings: SettingsStore

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                let c = settings.gridColor
                return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
            },
            set: { newValue in
                guard let ns = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                settings.gridColor = SettingsStore.RGBA(
                    r: ns.redComponent, g: ns.greenComponent,
                    b: ns.blueComponent, a: ns.alphaComponent)
            }
        )
    }

    var body: some View {
        Form {
            Section("Columns") {
                Stepper("Columns: \(settings.gridColumns)",
                        value: $settings.gridColumns, in: 1...24)
                HStack {
                    Slider(value: $settings.gridGutter, in: 0...96, step: 2) { Text("Gutter") }
                    Text("\(Int(settings.gridGutter)) pt")
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
                HStack {
                    Slider(value: $settings.gridMargin, in: 0...320, step: 4) { Text("Margin") }
                    Text("\(Int(settings.gridMargin)) pt")
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
            }
            Section("Baseline") {
                HStack {
                    Slider(value: $settings.gridBaseline, in: 0...48, step: 1) { Text("Row height") }
                    Text(settings.gridBaseline < 2 ? "off" : "\(Int(settings.gridBaseline)) pt")
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                }
            }
            Section("Appearance") {
                ColorPicker("Color", selection: colorBinding, supportsOpacity: true)
                Text("The grid spans every screen and ignores the mouse, so you can hold a layout up against a running app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Global shortcuts") {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(
                            combo: Binding(
                                get: { settings.combo(for: action) },
                                set: { settings.hotKeys[action] = $0 }
                            ))
                    }
                }
            }
            Section {
                Button("Reset to defaults") {
                    settings.hotKeys = SettingsStore.defaultHotKeys
                }
                Text("Click a shortcut, then press the keys you want. Every binding needs at least one of ⌘ ⌥ ⌃. esc cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// A click-to-record shortcut field.
private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var combo: KeyCombo

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.combo = combo
        view.onChange = { combo = $0 }
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.combo = combo
        view.onChange = { combo = $0 }
    }
}

/// The AppKit side of the recorder: it has to be a real view, because catching
/// a raw key code is something SwiftUI has no vocabulary for.
private final class RecorderView: NSView {
    var onChange: ((KeyCombo) -> Void)?
    var combo: KeyCombo = KeyCombo(keyCode: 0, modifiers: 0) {
        didSet { needsDisplay = true }
    }

    private var recording = false {
        didSet {
            needsDisplay = true
            if recording {
                HotKeyCenter.shared.suspend()
            } else {
                HotKeyCenter.shared.resume()
            }
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 132, height: 24) }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            recording = false
            window?.makeFirstResponder(nil)
            return
        }
        let modifiers = KeyCombo.carbonModifiers(from: event.modifierFlags)
        // A global shortcut without a modifier would eat the key everywhere.
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            NSSound.beep()
            return
        }
        let recorded = KeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        combo = recorded
        onChange?(recorded)
        recording = false
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.14)
                   : NSColor.quaternaryLabelColor.withAlphaComponent(0.35)).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = recording ? "Press keys…" : combo.display
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: recording ? NSColor.controlAccentColor : NSColor.labelColor,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                y: (bounds.height - size.height) / 2))
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Sextant at login", isOn: $settings.launchAtLogin)
            }
            Section("Permissions") {
                Text("The loupe and the screen freeze read pixels, which macOS counts as screen recording. The crosshair, the guides, the grid and the ruler need no permission at all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Screen Recording settings") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                    NSWorkspace.shared.open(url)
                }
            }
            Section("Files") {
                Text("Settings, guides and the colour palette are plain JSON in ~/Library/Application Support/Sextant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([SettingsStore.supportDirectory])
                }
            }
        }
        .formStyle(.grouped)
    }
}
