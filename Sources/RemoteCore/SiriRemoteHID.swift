import Foundation

public struct HIDUsage: Hashable, Sendable, CustomStringConvertible {
    public let page: UInt32
    public let usage: UInt32

    public init(page: UInt32, usage: UInt32) {
        self.page = page
        self.usage = usage
    }

    public var description: String { String(format: "0x%02X:0x%02X", page, usage) }
}

/// What we know about the Siri Remote's Bluetooth LE HID interfaces.
///
/// The 2nd-gen remote (product 0x0314) reports every button as a 1-bit field in a single
/// Consumer Control report (report ID 0xFB). The touch surface is a separate Digitizer interface
/// that macOS turns into an `AppleMultitouchDevice`.
public enum SiriRemoteHID {
    /// Apple's Bluetooth SIG company identifier, used as the HID vendor ID over Bluetooth LE.
    public static let vendorID = 0x004C
    public static let transport = "Bluetooth Low Energy"

    /// Product IDs macOS's AppleBluetoothRemote driver matches (its ProductIDArray).
    public static let knownModels: [Int: String] = [
        0x0266: "Siri Remote (1st gen)",
        0x026D: "Siri Remote (1st gen)",
        0x0314: "Siri Remote (2nd gen or later)",
        0x0315: "Siri Remote (2nd gen or later)",
    ]

    public static func modelName(productID: Int) -> String {
        knownModels[productID] ?? String(format: "Apple Remote (0x%04X)", productID)
    }

    public static let buttonUsages: [HIDUsage: RemoteButton] = [
        HIDUsage(page: 0x0C, usage: 0x60): .tv,          // Data On Screen
        HIDUsage(page: 0x0C, usage: 0xE9): .volumeUp,    // Volume Increment
        HIDUsage(page: 0x0C, usage: 0xEA): .volumeDown,  // Volume Decrement
        HIDUsage(page: 0x0C, usage: 0x80): .select,      // Selection
        HIDUsage(page: 0x0C, usage: 0x30): .power,       // Power
        HIDUsage(page: 0x0C, usage: 0x04): .siri,        // Microphone
        HIDUsage(page: 0x01, usage: 0x86): .back,        // Generic Desktop: System App Menu
        HIDUsage(page: 0x0C, usage: 0xE2): .mute,        // Mute
        HIDUsage(page: 0x0C, usage: 0xCD): .playPause,   // Play/Pause
        HIDUsage(page: 0x0C, usage: 0x42): .up,          // Menu Up
        HIDUsage(page: 0x0C, usage: 0x45): .right,       // Menu Right
        HIDUsage(page: 0x0C, usage: 0x43): .down,        // Menu Down
        HIDUsage(page: 0x0C, usage: 0x44): .left,        // Menu Left
        // 1st-gen remote equivalents.
        HIDUsage(page: 0x0C, usage: 0x40): .back,        // Menu
        HIDUsage(page: 0x0C, usage: 0x41): .select,      // Menu Pick
        HIDUsage(page: 0x0C, usage: 0x223): .tv,         // AC Home
    ]

    /// The clickpad has a single mechanical switch; like Apple TV, the pressed "button" comes from where the
    /// finger is when it clicks. Coordinates are normalised 0...1 with y up. The centre circle is about 56% of
    /// the pad's diameter.
    public static let clickpadCentreRadius = 0.27

    public static func clickpadButton(x: Double, y: Double) -> RemoteButton {
        let dx = x - 0.5
        let dy = y - 0.5
        if !isOnClickpadRing(x: x, y: y) { return .select }
        if abs(dx) > abs(dy) { return dx > 0 ? .right : .left }
        return dy > 0 ? .up : .down
    }

    /// True outside the centre circle, on the ring where the four directions sit.
    public static func isOnClickpadRing(x: Double, y: Double) -> Bool {
        let dx = x - 0.5
        let dy = y - 0.5
        return (dx * dx + dy * dy).squareRoot() >= clickpadCentreRadius
    }

    /// A consumer-control interface counts as a remote if it has the four clickpad directions.
    /// Keyboards and mice never report Menu Up/Down/Left/Right.
    public static func looksLikeRemote(usages: Set<HIDUsage>) -> Bool {
        let directions: [UInt32] = [0x42, 0x43, 0x44, 0x45]
        return directions.allSatisfy { usages.contains(HIDUsage(page: 0x0C, usage: $0)) }
    }

    /// Friendly name for one of the remote's HID interfaces, keyed by its primary usage.
    public static func interfaceName(page: Int, usage: Int) -> String {
        switch (page, usage) {
        case (0x0C, 0x01): "Buttons"
        case (0x0D, _): "Touch surface"
        case (0x0C, 0x04): "Microphone"
        case (0x0C, _): "Consumer aux"
        case (0x20, _): "Motion sensors"
        case (0xFF00, _): "Vendor"
        default: String(format: "Page 0x%X/0x%X", page, usage)
        }
    }
}
