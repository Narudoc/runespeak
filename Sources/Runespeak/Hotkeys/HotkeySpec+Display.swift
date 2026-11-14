import AppKit
import Carbon.HIToolbox
import RunespeakCore

extension HotkeySpec {
    /// Modifier mask in the form RegisterEventHotKey expects.
    var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if command { mask |= UInt32(cmdKey) }
        if option { mask |= UInt32(optionKey) }
        if control { mask |= UInt32(controlKey) }
        if shift { mask |= UInt32(shiftKey) }
        return mask
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        if shift { flags.insert(.shift) }
        return flags
    }

    init(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) {
        self.init(keyCode: UInt32(keyCode),
                  command: modifierFlags.contains(.command),
                  option: modifierFlags.contains(.option),
                  control: modifierFlags.contains(.control),
                  shift: modifierFlags.contains(.shift))
    }

    /// From a key-down event; nil for any other event type.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        self.init(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
    }

    /// "⌃⌥T", "⇧↩" — modifiers in the order macOS menus use, then the key.
    var displayString: String {
        HotkeySpec.modifierSymbols(modifierFlags) + HotkeySpec.keyName(for: keyCode)
    }

    static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    var isFunctionKey: Bool { HotkeySpec.functionKeyNames[keyCode] != nil }

    /// Keys that do not type a character (Return, Tab, arrows, F-keys ...).
    var isNonTextKey: Bool { isFunctionKey || HotkeySpec.nonTextKeyNames[keyCode] != nil }

    /// nil when the combination is acceptable as a global hotkey, otherwise a Korean reason.
    /// A bare text key (or Shift + text key) would swallow ordinary typing everywhere.
    var rejectionReason: String? {
        if isFunctionKey { return nil }
        if command || option || control { return nil }
        if shift {
            return isNonTextKey ? nil : "⌃ ⌥ ⌘ 중 하나와 함께 눌러 주세요"
        }
        return "⌃ ⌥ ⇧ ⌘ 와 함께 눌러 주세요"
    }

    static func keyName(for keyCode: UInt32) -> String {
        if let name = nonTextKeyNames[keyCode] { return name }
        if let name = functionKeyNames[keyCode] { return name }
        if let name = keypadNames[keyCode] { return name }
        if keyCode == UInt32(kVK_Space) { return "Space" }
        if let ch = layoutCharacter(for: keyCode) { return ch }
        if let name = ansiFallbackNames[keyCode] { return name }
        return "키 \(keyCode)"
    }

    private static let nonTextKeyNames: [UInt32: String] = [
        UInt32(kVK_Return): "↩", UInt32(kVK_ANSI_KeypadEnter): "⌅", UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_Escape): "⎋",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟", UInt32(kVK_Help): "Help",
    ]

    private static let functionKeyNames: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
    ]

    private static let keypadNames: [UInt32: String] = [
        UInt32(kVK_ANSI_Keypad0): "숫자패드 0", UInt32(kVK_ANSI_Keypad1): "숫자패드 1",
        UInt32(kVK_ANSI_Keypad2): "숫자패드 2", UInt32(kVK_ANSI_Keypad3): "숫자패드 3",
        UInt32(kVK_ANSI_Keypad4): "숫자패드 4", UInt32(kVK_ANSI_Keypad5): "숫자패드 5",
        UInt32(kVK_ANSI_Keypad6): "숫자패드 6", UInt32(kVK_ANSI_Keypad7): "숫자패드 7",
        UInt32(kVK_ANSI_Keypad8): "숫자패드 8", UInt32(kVK_ANSI_Keypad9): "숫자패드 9",
        UInt32(kVK_ANSI_KeypadDecimal): "숫자패드 .", UInt32(kVK_ANSI_KeypadPlus): "숫자패드 +",
        UInt32(kVK_ANSI_KeypadMinus): "숫자패드 -", UInt32(kVK_ANSI_KeypadMultiply): "숫자패드 *",
        UInt32(kVK_ANSI_KeypadDivide): "숫자패드 /", UInt32(kVK_ANSI_KeypadEquals): "숫자패드 =",
        UInt32(kVK_ANSI_KeypadClear): "숫자패드 Clear",
    ]

    /// Used only if the keyboard layout cannot be queried.
    private static let ansiFallbackNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
        12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
    ]

    /// The character the key produces on the user's Latin layout (a Korean input source is
    /// active most of the time, and "ㅅ" would be a confusing name for the T key).
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status: OSStatus = data.withUnsafeBytes { buffer in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(layout, UInt16(truncatingIfNeeded: keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length).uppercased()
        guard let scalar = s.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar),
              !CharacterSet.whitespacesAndNewlines.contains(scalar) else { return nil }
        return s
    }
}
