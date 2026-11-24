import AppKit
import Carbon.HIToolbox

/// A modifier-plus-key combination, in the Carbon units `RegisterEventHotKey` wants.
struct Chord: Equatable, Sendable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, …), not `NSEvent.ModifierFlags`.
    var modifiers: UInt32

    /// Three modifiers makes a collision with an app shortcut unlikely, and P is
    /// mnemonic. Anything with fewer will eventually shadow something the user cares
    /// about.
    static let `default` = Chord(
        keyCode: UInt32(kVK_ANSI_P),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        self.keyCode = UInt32(keyCode)
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        self.modifiers = carbon
    }

    /// Shift alone is not a chord: it just types a capital letter.
    var hasNonShiftModifier: Bool {
        modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    var isCommandOnly: Bool {
        modifiers == UInt32(cmdKey)
    }

    /// Apple's canonical order is Control, Option, Shift, Command.
    var display: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + Self.keyName(for: keyCode)
    }

    // MARK: - Key names

    static func keyName(for keyCode: UInt32) -> String {
        if let named = specialNames[Int(keyCode)] { return named }
        return translated(keyCode)?.uppercased() ?? "Key \(keyCode)"
    }

    private static let specialNames: [Int: String] = [
        kVK_Space: "Space",
        kVK_Return: "Return",
        kVK_Tab: "Tab",
        kVK_Escape: "Escape",
        kVK_Delete: "Delete",
        kVK_ForwardDelete: "Forward Delete",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_Home: "Home",
        kVK_End: "End",
        kVK_PageUp: "Page Up",
        kVK_PageDown: "Page Down",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Ask the current keyboard layout what this key types unmodified, so the chord reads
    /// correctly on a layout that is not US QWERTY.
    private static func translated(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
            .takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(paramErr)
            }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeys,
                characters.count,
                &length,
                &characters
            )
        }

        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}
