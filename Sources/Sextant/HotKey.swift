import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut: a virtual key code plus Carbon modifier flags.
struct KeyCombo: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon mask: `cmdKey | optionKey | shiftKey | controlKey`.
    var modifiers: UInt32

    /// The shortcut as macOS would print it, e.g. `⌥⌘X`.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + KeyCombo.name(for: keyCode)
    }

    /// Carbon flags from an AppKit event's modifier flags.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }

    /// A printable name for a virtual key code. Covers the keys anyone is
    /// likely to bind; anything else falls back to its number.
    static func name(for keyCode: UInt32) -> String {
        let names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
            kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
            kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "esc",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return names[Int(keyCode)] ?? "key \(keyCode)"
    }
}

/// Everything Sextant can be told to do from anywhere in the system.
enum HotKeyAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case crosshair
    case loupe
    case measure
    case grid
    case freeze
    case dropGuide
    case clearGuides
    case palette

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crosshair: return "Toggle crosshair"
        case .loupe: return "Toggle loupe"
        case .measure: return "Toggle measure"
        case .grid: return "Toggle layout grid"
        case .freeze: return "Freeze the screen"
        case .dropGuide: return "Drop guides at pointer"
        case .clearGuides: return "Clear all guides"
        case .palette: return "Show colour palette"
        }
    }

    var defaultCombo: KeyCombo {
        let option = UInt32(optionKey | cmdKey)
        let optionShift = UInt32(optionKey | shiftKey | cmdKey)
        switch self {
        case .crosshair: return KeyCombo(keyCode: UInt32(kVK_ANSI_X), modifiers: option)
        case .loupe: return KeyCombo(keyCode: UInt32(kVK_ANSI_L), modifiers: option)
        case .measure: return KeyCombo(keyCode: UInt32(kVK_ANSI_M), modifiers: option)
        case .grid: return KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: option)
        case .freeze: return KeyCombo(keyCode: UInt32(kVK_ANSI_F), modifiers: option)
        case .dropGuide: return KeyCombo(keyCode: UInt32(kVK_ANSI_G), modifiers: option)
        case .clearGuides: return KeyCombo(keyCode: UInt32(kVK_ANSI_G), modifiers: optionShift)
        case .palette: return KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: option)
        }
    }
}

/// System-wide hotkeys via Carbon RegisterEventHotKey — no Accessibility
/// permission needed. Bindings are user-configurable and live in settings.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// Invoked on the main thread with the action that fired.
    var onTrigger: ((HotKeyAction) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var bindings: [HotKeyAction: KeyCombo] = [:]
    private var suspended = false

    private init() {}

    /// Registers `bindings`, replacing whatever was registered before.
    func apply(_ bindings: [HotKeyAction: KeyCombo]) {
        self.bindings = bindings
        guard !suspended else { return }
        installHandlerIfNeeded()
        unregisterAll()
        for (action, combo) in bindings {
            register(combo, for: action)
        }
    }

    /// Releases every binding — used while a shortcut is being recorded, so the
    /// keystroke being typed reaches the recorder instead of firing.
    func suspend() {
        suspended = true
        unregisterAll()
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        apply(bindings)
    }

    // MARK: - Carbon plumbing

    private func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    private func register(_ combo: KeyCombo, for action: HotKeyAction) {
        var ref: EventHotKeyRef?
        let index = HotKeyAction.allCases.firstIndex(of: action) ?? 0
        let hotKeyID = EventHotKeyID(signature: OSType(0x5358_544E), // 'SXTN'
                                     id: UInt32(index + 1))
        RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
        if let ref { refs.append(ref) }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let index = Int(hkID.id) - 1
            MainActor.assumeIsolated {
                guard index >= 0, index < HotKeyAction.allCases.count else { return }
                center.onTrigger?(HotKeyAction.allCases[index])
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }
}
