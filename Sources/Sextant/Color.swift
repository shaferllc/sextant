import AppKit

/// A colour read off the screen, in sRGB.
struct SampledColor: Equatable, Codable {
    var r: Double
    var g: Double
    var b: Double

    static let black = SampledColor(r: 0, g: 0, b: 0)

    init(r: Double, g: Double, b: Double) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
    }

    init(r8: Int, g8: Int, b8: Int) {
        self.init(r: Double(r8) / 255, g: Double(g8) / 255, b: Double(b8) / 255)
    }

    var r8: Int { Int((r * 255).rounded()) }
    var g8: Int { Int((g * 255).rounded()) }
    var b8: Int { Int((b * 255).rounded()) }

    var hex: String { String(format: "#%02X%02X%02X", r8, g8, b8) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

    /// Hue in degrees, saturation and lightness in 0…1.
    var hsl: (h: Double, s: Double, l: Double) {
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let delta = maxV - minV
        let l = (maxV + minV) / 2
        guard delta > 0 else { return (0, 0, l) }
        let s = delta / (1 - abs(2 * l - 1))
        var h: Double
        switch maxV {
        case r: h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
        case g: h = 60 * (((b - r) / delta) + 2)
        default: h = 60 * (((r - g) / delta) + 4)
        }
        if h < 0 { h += 360 }
        return (h, s, l)
    }

    /// WCAG 2.1 relative luminance.
    var luminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio, 1…21.
    static func contrastRatio(_ a: SampledColor, _ b: SampledColor) -> Double {
        let high = max(a.luminance, b.luminance)
        let low = min(a.luminance, b.luminance)
        return (high + 0.05) / (low + 0.05)
    }

    /// The strongest WCAG grade a ratio earns for body-size text.
    static func wcagGrade(_ ratio: Double) -> String {
        if ratio >= 7 { return "AAA" }
        if ratio >= 4.5 { return "AA" }
        if ratio >= 3 { return "AA Large" }
        return "Fail"
    }
}

/// How a sampled colour is written when it lands on the clipboard.
enum ColorFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case hex
    case rgb
    case hsl
    case components
    case floats
    case swiftUI
    case appKit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hex: return "Hex"
        case .rgb: return "CSS rgb()"
        case .hsl: return "CSS hsl()"
        case .components: return "R G B"
        case .floats: return "Float components"
        case .swiftUI: return "SwiftUI Color"
        case .appKit: return "AppKit NSColor"
        }
    }

    /// A short tag drawn in the loupe so you can see which format is armed.
    var tag: String {
        switch self {
        case .hex: return "HEX"
        case .rgb: return "RGB"
        case .hsl: return "HSL"
        case .components: return "255"
        case .floats: return "0.0"
        case .swiftUI: return "SWIFT"
        case .appKit: return "NS"
        }
    }

    func string(for color: SampledColor) -> String {
        switch self {
        case .hex:
            return color.hex
        case .rgb:
            return "rgb(\(color.r8), \(color.g8), \(color.b8))"
        case .hsl:
            let (h, s, l) = color.hsl
            return String(format: "hsl(%.0f, %.0f%%, %.0f%%)", h, s * 100, l * 100)
        case .components:
            return "\(color.r8) \(color.g8) \(color.b8)"
        case .floats:
            return String(format: "%.3f, %.3f, %.3f", color.r, color.g, color.b)
        case .swiftUI:
            return String(format: "Color(.sRGB, red: %.3f, green: %.3f, blue: %.3f)",
                          color.r, color.g, color.b)
        case .appKit:
            return String(format: "NSColor(srgbRed: %.3f, green: %.3f, blue: %.3f, alpha: 1)",
                          color.r, color.g, color.b)
        }
    }

    var next: ColorFormat {
        let all = ColorFormat.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }
}
