import Foundation

/// Per-mode button → action table.
public struct ButtonMapping: Codable, Equatable, Sendable {
    public var remote: [RemoteButton: RemoteAction]
    public var trackpad: [RemoteButton: RemoteAction]

    public init(remote: [RemoteButton: RemoteAction], trackpad: [RemoteButton: RemoteAction]) {
        self.remote = remote
        self.trackpad = trackpad
    }

    public func action(for button: RemoteButton, in mode: RemoteMode) -> RemoteAction {
        switch mode {
        case .remote: remote[button] ?? Self.defaultRemote[button] ?? .none
        case .trackpad: trackpad[button] ?? Self.defaultTrackpad[button] ?? .none
        }
    }

    public mutating func set(_ action: RemoteAction, for button: RemoteButton, in mode: RemoteMode) {
        switch mode {
        case .remote: remote[button] = action
        case .trackpad: trackpad[button] = action
        }
    }

    public static let defaultRemote: [RemoteButton: RemoteAction] = [
        .up: RemoteAction(.volumeUp),
        .down: RemoteAction(.volumeDown),
        .left: RemoteAction(.previousTrack),
        .right: RemoteAction(.nextTrack),
        .select: RemoteAction(.playPause),
        .back: .key(KeyCatalog.leftArrow),
        .tv: .key(KeyCatalog.rightArrow),
        .playPause: RemoteAction(.playPause),
        .mute: RemoteAction(.mute),
        // Quarter-step volume, the same as pressing ⇧⌥ with the volume keys.
        .volumeUp: RemoteAction(.volumeUpFine),
        .volumeDown: RemoteAction(.volumeDownFine),
        .power: RemoteAction(.sleepDisplay),
        .siri: RemoteAction(.toggleMode),
    ]

    public static let defaultTrackpad: [RemoteButton: RemoteAction] = {
        var map = defaultRemote
        for button in RemoteButton.allCases where button.isClickpad {
            map[button] = RemoteAction(.leftClick)
        }
        map[.back] = RemoteAction(.rightClick)
        return map
    }()

    public static let defaults = ButtonMapping(remote: defaultRemote, trackpad: defaultTrackpad)

    /// Bump when defaults change in a way saved mappings should pick up.
    public static let currentVersion = 2

    /// Brings a mapping saved by an older version up to date, leaving anything the user customised alone.
    public mutating func migrate(from version: Int) {
        if version < 2 {
            // v2: the volume rocker defaults to fine (quarter) steps.
            for button in [RemoteButton.volumeUp, .volumeDown] {
                let old = RemoteAction(button == .volumeUp ? .volumeUp : .volumeDown)
                let new = RemoteAction(button == .volumeUp ? .volumeUpFine : .volumeDownFine)
                if remote[button] == old { remote[button] = new }
                if trackpad[button] == old { trackpad[button] = new }
            }
        }
    }
}
