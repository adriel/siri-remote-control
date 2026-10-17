import Foundation

/// What a button press does. `keyboardShortcut` uses `RemoteAction.shortcut`.
public enum ActionKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case none
    case volumeUp, volumeDown, volumeUpFine, volumeDownFine, mute
    case playPause, nextTrack, previousTrack, fastForward, rewind
    case brightnessUp, brightnessDown
    case keyboardShortcut
    case leftClick, rightClick, middleClick
    case toggleMode, switchToRemoteMode, switchToTrackpadMode
    case sleepDisplay, lockScreen, missionControl

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "Do Nothing"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .volumeUpFine: "Volume Up (Fine)"
        case .volumeDownFine: "Volume Down (Fine)"
        case .mute: "Mute / Unmute"
        case .playPause: "Play / Pause"
        case .nextTrack: "Next Track"
        case .previousTrack: "Previous Track"
        case .fastForward: "Fast Forward"
        case .rewind: "Rewind"
        case .brightnessUp: "Brightness Up"
        case .brightnessDown: "Brightness Down"
        case .keyboardShortcut: "Keyboard Key…"
        case .leftClick: "Left Click"
        case .rightClick: "Right Click"
        case .middleClick: "Middle Click"
        case .toggleMode: "Toggle Remote/Trackpad Mode"
        case .switchToRemoteMode: "Switch to Remote Mode"
        case .switchToTrackpadMode: "Switch to Trackpad Mode"
        case .sleepDisplay: "Sleep Display"
        case .lockScreen: "Lock Screen"
        case .missionControl: "Mission Control"
        }
    }

    public enum Group: String, CaseIterable, Identifiable, Sendable {
        case basic, media, keyboard, mouse, mode, system
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .basic: ""
            case .media: "Media"
            case .keyboard: "Keyboard"
            case .mouse: "Mouse"
            case .mode: "Mode"
            case .system: "System"
            }
        }
        public var kinds: [ActionKind] { ActionKind.allCases.filter { $0.group == self } }
    }

    public var group: Group {
        switch self {
        case .none: .basic
        case .volumeUp, .volumeDown, .volumeUpFine, .volumeDownFine, .mute, .playPause, .nextTrack, .previousTrack, .fastForward, .rewind: .media
        case .keyboardShortcut: .keyboard
        case .leftClick, .rightClick, .middleClick: .mouse
        case .toggleMode, .switchToRemoteMode, .switchToTrackpadMode: .mode
        case .brightnessUp, .brightnessDown, .sleepDisplay, .lockScreen, .missionControl: .system
        }
    }

    /// Actions that auto-repeat while the button is held, like a keyboard key.
    public var repeatsWhileHeld: Bool {
        switch self {
        case .volumeUp, .volumeDown, .volumeUpFine, .volumeDownFine, .brightnessUp, .brightnessDown, .keyboardShortcut: true
        default: false
        }
    }

    /// Actions that synthesise input events and therefore need the Accessibility permission.
    public var needsAccessibility: Bool {
        switch self {
        case .none, .toggleMode, .switchToRemoteMode, .switchToTrackpadMode, .sleepDisplay, .missionControl: false
        default: true
        }
    }
}

public struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = ModifierSet(rawValue: 1 << 0)
    public static let option = ModifierSet(rawValue: 1 << 1)
    public static let shift = ModifierSet(rawValue: 1 << 2)
    public static let command = ModifierSet(rawValue: 1 << 3)

    public var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

public struct KeyShortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ModifierSet

    public init(keyCode: UInt16, modifiers: ModifierSet = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public var displayString: String { modifiers.symbols + KeyCatalog.name(for: keyCode) }
}

public struct RemoteAction: Codable, Hashable, Sendable {
    public var kind: ActionKind
    public var shortcut: KeyShortcut?

    public init(_ kind: ActionKind, shortcut: KeyShortcut? = nil) {
        self.kind = kind
        self.shortcut = shortcut
    }

    public static let none = RemoteAction(.none)
    public static func key(_ code: UInt16, _ modifiers: ModifierSet = []) -> RemoteAction {
        RemoteAction(.keyboardShortcut, shortcut: KeyShortcut(keyCode: code, modifiers: modifiers))
    }

    public var displayName: String {
        if kind == .keyboardShortcut {
            return "Key " + (shortcut?.displayString ?? "(none)")
        }
        return kind.displayName
    }
}

/// macOS virtual key codes (Carbon `kVK_*`) offered in the key picker.
public enum KeyCatalog {
    public struct Key: Identifiable, Hashable, Sendable {
        public let code: UInt16
        public let name: String
        public var id: UInt16 { code }
    }

    public static let leftArrow: UInt16 = 0x7B
    public static let rightArrow: UInt16 = 0x7C
    public static let downArrow: UInt16 = 0x7D
    public static let upArrow: UInt16 = 0x7E
    public static let space: UInt16 = 0x31
    public static let escape: UInt16 = 0x35
    public static let q: UInt16 = 0x0C

    public static let all: [Key] = {
        var keys: [Key] = [
            Key(code: leftArrow, name: "←"), Key(code: rightArrow, name: "→"),
            Key(code: upArrow, name: "↑"), Key(code: downArrow, name: "↓"),
            Key(code: space, name: "Space"), Key(code: 0x24, name: "Return"),
            Key(code: escape, name: "Esc"), Key(code: 0x30, name: "Tab"),
            Key(code: 0x33, name: "Delete"), Key(code: 0x75, name: "Fwd Delete"),
            Key(code: 0x74, name: "Page Up"), Key(code: 0x79, name: "Page Down"),
            Key(code: 0x73, name: "Home"), Key(code: 0x77, name: "End"),
        ]
        let fKeys: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
        for (i, code) in fKeys.enumerated() { keys.append(Key(code: code, name: "F\(i + 1)")) }
        let letters: [(String, UInt16)] = [
            ("A", 0x00), ("B", 0x0B), ("C", 0x08), ("D", 0x02), ("E", 0x0E), ("F", 0x03), ("G", 0x05),
            ("H", 0x04), ("I", 0x22), ("J", 0x26), ("K", 0x28), ("L", 0x25), ("M", 0x2E), ("N", 0x2D),
            ("O", 0x1F), ("P", 0x23), ("Q", 0x0C), ("R", 0x0F), ("S", 0x01), ("T", 0x11), ("U", 0x20),
            ("V", 0x09), ("W", 0x0D), ("X", 0x07), ("Y", 0x10), ("Z", 0x06),
        ]
        keys += letters.map { Key(code: $0.1, name: $0.0) }
        let digits: [(String, UInt16)] = [
            ("0", 0x1D), ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15),
            ("5", 0x17), ("6", 0x16), ("7", 0x1A), ("8", 0x1C), ("9", 0x19),
        ]
        keys += digits.map { Key(code: $0.1, name: $0.0) }
        let punctuation: [(String, UInt16)] = [
            ("-", 0x1B), ("=", 0x18), ("[", 0x21), ("]", 0x1E), (";", 0x29), ("'", 0x27),
            (",", 0x2B), (".", 0x2F), ("/", 0x2C), ("\\", 0x2A), ("`", 0x32),
        ]
        keys += punctuation.map { Key(code: $0.1, name: $0.0) }
        return keys
    }()

    public static func name(for code: UInt16) -> String {
        all.first { $0.code == code }?.name ?? String(format: "Key 0x%02X", code)
    }
}
