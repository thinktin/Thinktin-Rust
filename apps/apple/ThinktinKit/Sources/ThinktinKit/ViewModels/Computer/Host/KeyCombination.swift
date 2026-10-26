import Foundation

/// `computer_key` 的按键（WBS 14.4）：`return`、`cmd+s`、`cmd+shift+t` 这样的写法解析成 macOS 的虚拟键码和修饰键。
/// 键码是 Carbon 的 `kVK_*`（和键盘布局无关的物理键位，按美式布局起名），App 用它造 `CGEvent`。
public struct KeyCombination: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    public var keyCode: UInt16
    public var modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// 解析；写错了返回给 agent 看的说明（英文，和工具说明一样）。
    public static func parse(_ text: String) -> Result<KeyCombination, KeyCombinationError> {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty, parts.dropLast().allSatisfy({ !$0.isEmpty }) else {
            return .failure(.malformed(text))
        }
        var modifiers: Modifiers = []
        for name in parts.dropLast() {
            guard let modifier = modifierNames[name] else { return .failure(.unknownModifier(name)) }
            modifiers.insert(modifier)
        }
        guard let code = keyCodes[last] else { return .failure(.unknownKey(last)) }
        return .success(KeyCombination(keyCode: code, modifiers: modifiers))
    }

    static let modifierNames: [String: Modifiers] = [
        "cmd": .command, "command": .command, "meta": .command, "super": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
        "alt": .option, "option": .option, "opt": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "⌃": .control,
    ]

    static let keyCodes: [String: UInt16] = {
        var codes: [String: UInt16] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08,
            "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
            "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B,
            "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25,
            "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E,
            ".": 0x2F, "`": 0x32,
            "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "backspace": 0x33, "delete": 0x33,
            "escape": 0x35, "esc": 0x35, "forwarddelete": 0x75, "del": 0x75, "home": 0x73, "end": 0x77,
            "pageup": 0x74, "pagedown": 0x79, "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
            "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
            "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        ]
        // 常见的别名：arrowleft、page_up、page down 这类。
        for (alias, name) in [
            ("arrowleft", "left"), ("arrowright", "right"), ("arrowup", "up"), ("arrowdown", "down"),
            ("page_up", "pageup"), ("page_down", "pagedown"), ("pgup", "pageup"), ("pgdn", "pagedown"),
            ("forward_delete", "forwarddelete"), ("minus", "-"), ("equal", "="), ("comma", ","), ("period", "."),
            ("slash", "/"), ("semicolon", ";"), ("quote", "'"), ("backslash", "\\"), ("grave", "`"),
            ("bracketleft", "["), ("bracketright", "]"),
        ] {
            codes[alias] = codes[name]
        }
        return codes
    }()
}

public enum KeyCombinationError: Error, Hashable, Sendable, CustomStringConvertible {
    case malformed(String)
    case unknownModifier(String)
    case unknownKey(String)

    public var description: String {
        switch self {
        case .malformed(let text):
            "\"\(text)\" is not a key combination. Write keys like return, cmd+s or cmd+shift+t."
        case .unknownModifier(let name):
            "\"\(name)\" is not a modifier. Use cmd, shift, alt (option) or ctrl."
        case .unknownKey(let name):
            "\"\(name)\" is not a key. Use a letter, a digit, return, tab, space, escape, backspace, delete, arrows (left, right, up, down), home, end, pageup, pagedown or f1–f12."
        }
    }
}
