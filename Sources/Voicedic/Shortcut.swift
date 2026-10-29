import Foundation

/// A physical modifier key. Left and right are separate keys.
enum ModifierKey: String, Codable, CaseIterable, Sendable {
    case fn
    case leftControl, rightControl
    case leftOption, rightOption
    case leftShift, rightShift
    case leftCommand, rightCommand

    var symbol: String {
        switch self {
        case .fn: "fn"
        case .leftControl, .rightControl: "⌃"
        case .leftOption, .rightOption: "⌥"
        case .leftShift, .rightShift: "⇧"
        case .leftCommand, .rightCommand: "⌘"
        }
    }

    var side: String? {
        switch self {
        case .fn: nil
        case .leftControl, .leftOption, .leftShift, .leftCommand: "Left"
        case .rightControl, .rightOption, .rightShift, .rightCommand: "Right"
        }
    }

    /// The left key for either side, so ⌥ matches both option keys.
    var unsided: ModifierKey {
        switch self {
        case .rightControl: .leftControl
        case .rightOption: .leftOption
        case .rightShift: .leftShift
        case .rightCommand: .leftCommand
        default: self
        }
    }

    /// The modifier keys held down, from a CGEvent's or NSEvent's raw flags. Both use the NX layout: a
    /// device-independent bit per modifier, and device-dependent bits telling left from right.
    static func held(inFlags flags: UInt64) -> Set<ModifierKey> {
        var keys: Set<ModifierKey> = []
        if flags & 0x80_0000 != 0 { keys.insert(.fn) }
        let pairs: [(mask: UInt64, left: (ModifierKey, UInt64), right: (ModifierKey, UInt64))] = [
            (0x04_0000, (.leftControl, 0x0001), (.rightControl, 0x2000)),
            (0x08_0000, (.leftOption, 0x0020), (.rightOption, 0x0040)),
            (0x02_0000, (.leftShift, 0x0002), (.rightShift, 0x0004)),
            (0x10_0000, (.leftCommand, 0x0008), (.rightCommand, 0x0010)),
        ]
        for (mask, left, right) in pairs where flags & mask != 0 {
            let isRight = flags & right.1 != 0
            // Events from virtual keyboards can leave out the side. Call those left.
            if flags & left.1 != 0 || !isRight { keys.insert(left.0) }
            if isRight { keys.insert(right.0) }
        }
        return keys
    }
}

/// What to hold to dictate: modifier keys on their own (fn, right option, ⌃⌥) or a key with modifiers
/// (⌥Space, or a function key).
struct Shortcut: Codable, Hashable, Sendable {
    var modifiers: Set<ModifierKey>
    /// The non-modifier key's virtual key code. Nil for modifiers on their own.
    var keyCode: UInt16?
    /// The key's label from the keyboard layout it was recorded with.
    var keyName: String?

    static let fn = Shortcut(modifiers: [.fn])

    /// A single modifier on its own must be that exact key, so right option can dictate while left
    /// option still types special characters. Combinations match either side, like other shortcuts.
    private var isSingleModifier: Bool { keyCode == nil && modifiers.count == 1 }

    /// Whether exactly these modifiers are held, no more.
    func matches(_ held: Set<ModifierKey>) -> Bool {
        isSingleModifier ? held == modifiers : Self.unsided(held) == Self.unsided(modifiers)
    }

    /// Whether this shortcut's modifiers are all still held, ignoring any others.
    func isHeld(in held: Set<ModifierKey>) -> Bool {
        isSingleModifier
            ? held.isSuperset(of: modifiers) : Self.unsided(held).isSuperset(of: Self.unsided(modifiers))
    }

    var displayName: String {
        if isSingleModifier, let key = modifiers.first {
            return key.side.map { "\($0) \(key.symbol)" } ?? key.symbol
        }
        let unsided = Self.unsided(modifiers)
        var name = ModifierKey.allCases.filter { unsided.contains($0) && $0 != .fn }.map(\.symbol).joined()
        if let keyCode { name += keyName ?? "Key \(keyCode)" }
        return unsided.contains(.fn) ? "fn " + name : name
    }

    private static func unsided(_ keys: Set<ModifierKey>) -> Set<ModifierKey> {
        Set(keys.map(\.unsided))
    }

    // MARK: - Keys

    static let escapeKeyCode: UInt16 = 53

    /// F1–F20 can be a shortcut on their own. Other keys need a modifier besides shift, or they'd stop
    /// typing.
    static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    private static let namedKeys: [UInt16: String] = [
        49: "Space", 36: "Return", 76: "Enter", 48: "Tab", 51: "Delete", 117: "⌦", 114: "Help",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// A label for a key, given the character it types with no modifiers.
    static func keyName(for keyCode: UInt16, characters: String?) -> String {
        if let name = functionKeys[keyCode] ?? namedKeys[keyCode] { return name }
        if let characters, !characters.isEmpty, !characters.contains(where: \.isWhitespace) {
            return characters.uppercased()
        }
        return "Key \(keyCode)"
    }

    /// Nil if the shortcut is fine to use, otherwise why not.
    var problem: String? {
        guard let keyCode else { return modifiers.isEmpty ? "Press at least one key." : nil }
        if keyCode == Self.escapeKeyCode { return "Esc cancels dictation, so it can't start it." }
        let typing: Set<ModifierKey> = [.leftShift]
        if Self.unsided(modifiers).isSubset(of: typing), Self.functionKeys[keyCode] == nil {
            return "Add fn, ⌃, ⌥, or ⌘, or use a function key, so the key can still type."
        }
        return nil
    }
}
