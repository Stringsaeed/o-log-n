import AppKit
import Carbon

/// Carbon global hotkey. The handler is a non-capturing C function so it is safe under Swift 6.
@MainActor
final class HotkeyService {
    static let shared = HotkeyService()

    var onFire: () -> Void = {}
    var onTrayChord: (UInt32) -> Void = { _ in }
    private(set) var lastStatus: OSStatus = noErr
    /// Command-key registrations. The global ⌃⌥Space toggle is not one of these.
    var trayChordCount: Int { trayRefs.count }
    private var hotKeyRef: EventHotKeyRef?
    private var trayRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var installedCode: UInt32?
    private var installedMods: UInt32?

    func sync(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        if hotKeyRef != nil, installedCode == keyCode, installedMods == modifiers {
            return lastStatus
        }
        unregisterHotkey()
        let status = register(keyCode: keyCode, modifiers: modifiers)
        lastStatus = status
        return status
    }

    /// Command chords the tray handles. Carbon delivers these while another app stays frontmost;
    /// a local key monitor never sees them, because the active app takes command-key equivalents.
    func installTrayChords(_ chords: [TrayHotkeyChord]) {
        removeTrayChords()
        guard installHandler() == noErr else { return }
        for chord in chords {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                chord.keyCode,
                chord.modifiers,
                EventHotKeyID(signature: OSType(0x4F4C474E), id: chord.id),
                GetEventDispatcherTarget(),
                0,
                &ref)
            if status == noErr, let ref {
                trayRefs.append(ref)
            }
        }
    }

    func removeTrayChords() {
        for ref in trayRefs {
            UnregisterEventHotKey(ref)
        }
        trayRefs.removeAll()
    }

    func unregister() {
        removeTrayChords()
        unregisterHotkey()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        installedCode = nil
        installedMods = nil
    }

    func fire() {
        onFire()
    }

    func dispatch(id: UInt32) {
        if id == 1 {
            fire()
        } else if id != 0 {
            onTrayChord(id)
        }
    }

    private func register(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
        let install = installHandler()
        if install != noErr { return install }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F4C474E), id: 1)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref)
        if status == noErr {
            hotKeyRef = ref
            installedCode = keyCode
            installedMods = modifiers
        }
        return status
    }

    private func installHandler() -> OSStatus {
        if handlerRef != nil { return noErr }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotkeyCallback,
            1,
            &spec,
            nil,
            &ref)
        if status == noErr { handlerRef = ref }
        return status
    }

    private func unregisterHotkey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}

struct TrayHotkeyChord: Sendable {
    var id: UInt32
    var keyCode: UInt32
    var modifiers: UInt32
    var characters: String
    var option: Bool
    var shift: Bool

    /// Tray command chords (ux §5.2). Registered only while the tray is key.
    static let tray: [TrayHotkeyChord] = [
        TrayHotkeyChord(id: 10, keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey), characters: "v", option: false, shift: false),
        TrayHotkeyChord(id: 11, keyCode: UInt32(kVK_ANSI_O), modifiers: UInt32(cmdKey), characters: "o", option: false, shift: false),
        TrayHotkeyChord(id: 12, keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey), characters: "z", option: false, shift: false),
        TrayHotkeyChord(id: 13, keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey), characters: "1", option: false, shift: false),
        TrayHotkeyChord(id: 14, keyCode: UInt32(kVK_ANSI_2), modifiers: UInt32(cmdKey), characters: "2", option: false, shift: false),
        TrayHotkeyChord(id: 15, keyCode: UInt32(kVK_ANSI_C), modifiers: UInt32(cmdKey), characters: "c", option: false, shift: false),
        TrayHotkeyChord(id: 16, keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey), characters: "r", option: false, shift: false),
        TrayHotkeyChord(id: 17, keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey), characters: "q", option: false, shift: false),
        TrayHotkeyChord(id: 18, keyCode: UInt32(kVK_ANSI_Comma), modifiers: UInt32(cmdKey), characters: ",", option: false, shift: false),
        TrayHotkeyChord(id: 19, keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(cmdKey), characters: ".", option: false, shift: false),
        TrayHotkeyChord(id: 20, keyCode: UInt32(kVK_ANSI_Period), modifiers: UInt32(cmdKey | shiftKey), characters: ".", option: false, shift: true),
        TrayHotkeyChord(id: 21, keyCode: UInt32(kVK_Delete), modifiers: UInt32(cmdKey), characters: "", option: false, shift: false),
        TrayHotkeyChord(id: 22, keyCode: UInt32(kVK_Delete), modifiers: UInt32(cmdKey | optionKey), characters: "", option: true, shift: false),
    ]
}

private func hotKeyID(_ event: EventRef?) -> UInt32 {
    guard let event else { return 0 }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID)
    return status == noErr ? hotKeyID.id : 0
}

private let hotkeyCallback: EventHandlerProcPtr = { _, event, _ in
    let id = hotKeyID(event)
    if Thread.isMainThread {
        MainActor.assumeIsolated { HotkeyService.shared.dispatch(id: id) }
    } else {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { HotkeyService.shared.dispatch(id: id) }
        }
    }
    return noErr
}
