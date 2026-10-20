import Carbon
import Foundation

/// System-wide shortcuts via Carbon hot keys (no Accessibility permission needed).
/// Each shortcut is registered only while it's useful, so NotchBar never
/// shadows other apps' shortcuts unnecessarily. All modifiers are ⌃⌥.
final class HotKeys {
    enum Key: UInt32, CaseIterable {
        case allow = 1, deny, always, trust, jump, voice

        var keyCode: UInt32 {
            switch self {
            case .allow: return UInt32(kVK_ANSI_Y)
            case .deny: return UInt32(kVK_ANSI_N)
            case .always: return UInt32(kVK_ANSI_A)
            case .trust: return UInt32(kVK_ANSI_T)
            case .jump: return UInt32(kVK_ANSI_J)
            case .voice: return UInt32(kVK_ANSI_V)
            }
        }

        var label: String {
            switch self {
            case .allow: return "⌃⌥Y"
            case .deny: return "⌃⌥N"
            case .always: return "⌃⌥A"
            case .trust: return "⌃⌥T"
            case .jump: return "⌃⌥J"
            case .voice: return "⌃⌥V"
            }
        }
    }

    private var refs: [Key: EventHotKeyRef] = [:]
    private var handlers: [Key: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x4E_42_41_52 // 'NBAR'

    func setHandler(_ key: Key, _ handler: @escaping () -> Void) { handlers[key] = handler }

    /// Registers exactly the keys in `keys`, unregistering the rest.
    func setActive(_ keys: Set<Key>) {
        installHandlerOnce()
        for k in Key.allCases {
            let want = keys.contains(k)
            if want, refs[k] == nil {
                var ref: EventHotKeyRef?
                let status = RegisterEventHotKey(k.keyCode, UInt32(controlKey | optionKey),
                                                 EventHotKeyID(signature: signature, id: k.rawValue),
                                                 GetApplicationEventTarget(), 0, &ref)
                if status == noErr, let ref { refs[k] = ref }
            } else if !want, let ref = refs[k] {
                UnregisterEventHotKey(ref)
                refs[k] = nil
            }
        }
    }

    fileprivate func fire(_ id: UInt32) {
        guard let key = Key(rawValue: id) else { return }
        handlers[key]?()
    }

    private func installHandlerOnce() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let target = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { target.fire(hk.id) }
            return noErr
        }, 1, &spec, me, &eventHandler)
    }
}
