import AppKit

extension Shortcut {
    // Key-equivalent characters for non-printing keys (NSMenuItem semantics).
    public nonisolated static let upArrowKey = String(Character(UnicodeScalar(UInt32(NSUpArrowFunctionKey)) ?? UnicodeScalar(0)))
    public nonisolated static let downArrowKey = String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey)) ?? UnicodeScalar(0)))
    public nonisolated static let leftArrowKey = String(Character(UnicodeScalar(UInt32(NSLeftArrowFunctionKey)) ?? UnicodeScalar(0)))
    public nonisolated static let rightArrowKey = String(Character(UnicodeScalar(UInt32(NSRightArrowFunctionKey)) ?? UnicodeScalar(0)))
    public nonisolated static let returnKey = "\r"
    public nonisolated static let tabKey = "\t"
    public nonisolated static let escapeKey = "\u{1B}"
    public nonisolated static let deleteKey = "\u{8}"
    public nonisolated static let spaceKey = " "

    /// Modifier glyphs in macOS menu order: control, option, shift, command.
    public var modifierGlyphs: [String] {
        var glyphs: [String] = []
        if modifiers.contains(.control) { glyphs.append("⌃") }
        if modifiers.contains(.option) { glyphs.append("⌥") }
        if modifiers.contains(.shift) { glyphs.append("⇧") }
        if modifiers.contains(.command) { glyphs.append("⌘") }
        return glyphs
    }

    /// Glyph for the key itself, as menus show it.
    public var keyGlyph: String {
        switch key {
        case Self.upArrowKey: "↑"
        case Self.downArrowKey: "↓"
        case Self.leftArrowKey: "←"
        case Self.rightArrowKey: "→"
        case Self.returnKey: "↩"
        case Self.tabKey: "⇥"
        case Self.escapeKey: "⎋"
        case Self.deleteKey, "\u{7F}": "⌫"
        case Self.spaceKey: String(localized: "shortcut.key.space", defaultValue: "Space", bundle: .localizedModule)
        default: key.uppercased()
        }
    }

    /// What a keycap prints for `cap`, as a Mac keyboard labels its keys: modifiers keep their glyphs
    /// (⌘ ⌥ ⌃ ⇧), the named keys read as words ("return", "tab", "esc", "delete"), every other key as
    /// it is. Leo 2026-11-22: "this command palette's icons are really bad and not even properly
    /// depicting the keys"; a lone ↩ or ⇥ on a small cap read as an arrow, not a key.
    public nonisolated static func keycapLegend(_ cap: String) -> String {
        switch cap {
        case "↩", "⏎", "↵", "⌅", returnKey: "return"
        case "⇥", tabKey: "tab"
        case "⎋", "Esc", "ESC", escapeKey: "esc"
        case "⌫", "⌦", deleteKey, "\u{7F}": "delete"
        default: cap
        }
    }

    /// Whether `cap` is a modifier's glyph: a shortcut's stroke runs through its modifiers to the first
    /// other key, so in `["⌘", "J", "S"]` (a chord) the S starts a second stroke.
    public nonisolated static func isModifierKeycap(_ cap: String) -> Bool {
        ["⌃", "⌥", "⇧", "⌘", "fn"].contains(cap)
    }

    /// `caps` split into the strokes pressed one after another: `[["⌘", "J"], ["S"]]` for the chord ⌘J
    /// then S, one stroke for `["⇧", "⌘", "P"]`.
    public nonisolated static func keycapStrokes(_ caps: [String]) -> [[String]] {
        var strokes: [[String]] = []
        var current: [String] = []
        for cap in caps {
            current.append(cap)
            if !isModifierKeycap(cap) {
                strokes.append(current)
                current = []
            }
        }
        if !current.isEmpty { strokes.append(current) }
        return strokes
    }

    /// Separate keycaps, for rendering one badge per key: `["⇧", "⌘", "P"]`.
    public var keycaps: [String] { modifierGlyphs + [keyGlyph] }

    /// Compact menu-style text: `⇧⌘P`.
    public var displayString: String { keycaps.joined() }

    /// Words that let a search for "cmd shift p" or "command d" find this
    /// shortcut.
    public var searchTokens: [String] {
        var tokens: [String] = []
        if modifiers.contains(.control) { tokens += ["ctrl", "control", "⌃"] }
        if modifiers.contains(.option) { tokens += ["opt", "option", "alt", "⌥"] }
        if modifiers.contains(.shift) { tokens += ["shift", "⇧"] }
        if modifiers.contains(.command) { tokens += ["cmd", "command", "⌘"] }
        tokens.append(keyWord)
        tokens.append(displayString)
        return tokens
    }

    private var keyWord: String {
        switch key {
        case Self.upArrowKey: "up"
        case Self.downArrowKey: "down"
        case Self.leftArrowKey: "left"
        case Self.rightArrowKey: "right"
        case Self.returnKey: "return enter"
        case Self.tabKey: "tab"
        case Self.escapeKey: "escape"
        case Self.deleteKey, "\u{7F}": "delete"
        case Self.spaceKey: "space"
        default: key
        }
    }
}
