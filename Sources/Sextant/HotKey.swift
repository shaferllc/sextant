import AppKit
import Carbon.HIToolbox

/// System-wide hotkeys via Carbon RegisterEventHotKey — no Accessibility
/// permission needed. Two fixed bindings: ⌥⌘X (crosshair) and ⌥⌘L (loupe).
@MainActor
final class HotKeyCenter {
    enum ID: UInt32 {
        case crosshair = 1
        case loupe = 2
    }

    static let shared = HotKeyCenter()

    /// Invoked on the main thread with the binding that fired.
    var onTrigger: ((ID) -> Void)?

    private var refs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    private init() {}

    func registerDefaults() {
        installHandlerIfNeeded()
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        register(keyCode: UInt32(kVK_ANSI_X),
                 modifiers: UInt32(optionKey | cmdKey), id: .crosshair)
        register(keyCode: UInt32(kVK_ANSI_L),
                 modifiers: UInt32(optionKey | cmdKey), id: .loupe)
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: ID) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5358_544E), // 'SXTN'
                                     id: id.rawValue)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
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
            let number = hkID.id
            MainActor.assumeIsolated {
                if let id = ID(rawValue: number) { center.onTrigger?(id) }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }
}
