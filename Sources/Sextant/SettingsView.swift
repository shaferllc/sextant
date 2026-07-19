import SwiftUI

struct SettingsView: View {
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
            Section("Crosshair") {
                ColorPicker("Color", selection: colorBinding, supportsOpacity: true)
                HStack {
                    Slider(value: $settings.crosshairThickness, in: 0.5...4, step: 0.5) {
                        Text("Thickness")
                    }
                    Text(String(format: "%.1f pt", settings.crosshairThickness))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                Toggle("Show pointer coordinates", isOn: $settings.showCoordinates)
            }
            Section("Loupe") {
                Picker("Default zoom", selection: $settings.defaultZoom) {
                    ForEach([2.0, 4.0, 8.0, 16.0, 32.0], id: \.self) { zoom in
                        Text("\(Int(zoom))×").tag(zoom)
                    }
                }
                Text("While the loupe is open: + / − changes zoom, click it or press ⌘C to copy the hex color, esc closes it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Shortcuts") {
                LabeledContent("Toggle crosshair", value: "⌥⌘X")
                LabeledContent("Toggle loupe", value: "⌥⌘L")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .fixedSize()
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
