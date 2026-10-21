import AppKit
import Carbon.HIToolbox

/// Carbon 修饰键位（cmdKey=1<<8, shiftKey=1<<9, optionKey=1<<11, controlKey=1<<12）
enum CarbonModifierMasks {
    static let cmd: UInt32 = 1 << 8
    static let shift: UInt32 = 1 << 9
    static let option: UInt32 = 1 << 11
    static let control: UInt32 = 1 << 12
}

/// 全局快捷键（Carbon RegisterEventHotKey，可正确吞掉按键，不干扰其他 app）。
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var onFire: () -> Void = {}
    private var keyCode: UInt32 = 2 // kVK_ANSI_D
    private var modifiers: UInt32 = CarbonModifierMasks.option

    private static let signature: FourCharCode = 0x464C_5354 // 'FLST'

    private static let handler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        if status == noErr, hotKeyID.signature == HotkeyManager.signature, hotKeyID.id == 1 {
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.onFire() }
        }
        return noErr
    }

    func update(keyCode newCode: UInt32, modifiers newMods: UInt32, handler: @escaping () -> Void) {
        onFire = handler
        keyCode = newCode
        modifiers = newMods
        reregister()
    }

    private func reregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if eventHandlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let pointer = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), Self.handler, 1, &spec, pointer, &eventHandlerRef)
        }
        guard keyCode != 0 else { return }
        var newRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        if RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &newRef) == noErr {
            hotKeyRef = newRef
        }
    }

    // MARK: - 显示与转换

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= CarbonModifierMasks.cmd }
        if flags.contains(.option) { value |= CarbonModifierMasks.option }
        if flags.contains(.control) { value |= CarbonModifierMasks.control }
        if flags.contains(.shift) { value |= CarbonModifierMasks.shift }
        return value
    }

    static func display(keyCode: UInt32, modifiers: UInt32) -> String {
        var label = ""
        if modifiers & CarbonModifierMasks.control != 0 { label += "⌃" }
        if modifiers & CarbonModifierMasks.option != 0 { label += "⌥" }
        if modifiers & CarbonModifierMasks.shift != 0 { label += "⇧" }
        if modifiers & CarbonModifierMasks.cmd != 0 { label += "⌘" }
        return label + (keyNames[keyCode] ?? "#\(keyCode)")
    }

    private static let keyNames: [UInt32: String] = {
        var names: [UInt32: String] = [
            UInt32(kVK_Space): "Space",
            UInt32(kVK_Return): "↩",
            UInt32(kVK_Tab): "Tab",
            UInt32(kVK_Escape): "Esc",
        ]
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
            (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
            (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
            (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
            (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
            (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"),
        ]
        for (code, character) in letters { names[UInt32(code)] = character }
        for digit in 0...9 { names[UInt32(kVK_ANSI_0 + digit)] = String(digit) }
        for function in 1...12 { names[UInt32(kVK_F1 + function - 1)] = "F\(function)" }
        return names
    }()
}
