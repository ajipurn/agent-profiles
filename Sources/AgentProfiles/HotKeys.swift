import AppKit
import Carbon.HIToolbox

/// Global hotkeys: ⌘⌥1…⌘⌥9 switch to the Nth Claude profile, ⌃⌥1…⌃⌥9 to
/// the Nth Codex account. Carbon hotkeys because they are the one
/// global-shortcut API that needs no Accessibility or Input Monitoring
/// permission.
@MainActor
enum HotKeys {
    enum Group: UInt32 {
        case claude = 0
        case codex = 1

        var modifiers: Int {
            switch self {
            case .claude: cmdKey | optionKey
            case .codex: controlKey | optionKey
            }
        }
    }

    private static var refs: [EventHotKeyRef?] = []
    private static var handler: ((Group, Int) -> Void)?

    /// `onPress` gets the group and the 0-based position in its list.
    static func install(_ onPress: @escaping (Group, Int) -> Void) {
        handler = onPress

        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                    eventKind: UInt32(kEventHotKeyPressed))
        // C callback — no captures allowed, hence the static handler above.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let raw = id.id
            Task { @MainActor in
                guard let group = Group(rawValue: raw / 100) else { return }
                HotKeys.handler?(group, Int(raw % 100))
            }
            return noErr
        }, 1, &pressed, nil, nil)

        // Number-row key codes are not contiguous.
        let digitKeys: [Int] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for group in [Group.claude, .codex] {
            for (index, key) in digitKeys.enumerated() {
                var ref: EventHotKeyRef?
                let id = EventHotKeyID(signature: 0x4350_484B /* 'CPHK' */,
                                       id: group.rawValue * 100 + UInt32(index))
                RegisterEventHotKey(UInt32(key), UInt32(group.modifiers), id,
                                    GetApplicationEventTarget(), 0, &ref)
                refs.append(ref)
            }
        }
    }
}
