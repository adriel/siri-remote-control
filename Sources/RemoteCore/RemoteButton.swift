import Foundation

/// A physical button on the Siri Remote (2nd generation and later).
public enum RemoteButton: String, CaseIterable, Codable, Identifiable, Sendable, CodingKeyRepresentable {
    case up, down, left, right, select
    case back, tv, playPause, mute
    case volumeUp, volumeDown
    case power, siri

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .up: "Clickpad Up"
        case .down: "Clickpad Down"
        case .left: "Clickpad Left"
        case .right: "Clickpad Right"
        case .select: "Clickpad Centre"
        case .back: "Back"
        case .tv: "TV / Home"
        case .playPause: "Play/Pause"
        case .mute: "Mute"
        case .volumeUp: "Volume Up"
        case .volumeDown: "Volume Down"
        case .power: "Power"
        case .siri: "Siri (side button)"
        }
    }

    public var symbolName: String {
        switch self {
        case .up: "chevron.up.circle"
        case .down: "chevron.down.circle"
        case .left: "chevron.left.circle"
        case .right: "chevron.right.circle"
        case .select: "circle.circle"
        case .back: "chevron.left"
        case .tv: "tv"
        case .playPause: "playpause"
        case .mute: "speaker.slash"
        case .volumeUp: "plus"
        case .volumeDown: "minus"
        case .power: "power"
        case .siri: "mic"
        }
    }

    /// Buttons that are part of the touch-sensitive clickpad.
    public var isClickpad: Bool {
        switch self {
        case .up, .down, .left, .right, .select: true
        default: false
        }
    }
}

public enum RemoteMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case remote, trackpad

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .remote: "Remote Mode"
        case .trackpad: "Trackpad Mode"
        }
    }

    public var shortName: String {
        switch self {
        case .remote: "Remote"
        case .trackpad: "Trackpad"
        }
    }

    public var symbolName: String {
        switch self {
        case .remote: "appletvremote.gen4.fill"
        case .trackpad: "cursorarrow.motionlines"
        }
    }

    public var toggled: RemoteMode { self == .remote ? .trackpad : .remote }
}
