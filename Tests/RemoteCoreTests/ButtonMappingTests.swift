import XCTest
@testable import RemoteCore

final class ButtonMappingTests: XCTestCase {
    func testRemoteModeDefaultsMatchSpec() {
        let m = ButtonMapping.defaults
        XCTAssertEqual(m.action(for: .up, in: .remote).kind, .volumeUp)
        XCTAssertEqual(m.action(for: .down, in: .remote).kind, .volumeDown)
        XCTAssertEqual(m.action(for: .right, in: .remote).kind, .nextTrack)
        XCTAssertEqual(m.action(for: .left, in: .remote).kind, .previousTrack)
        XCTAssertEqual(m.action(for: .select, in: .remote).kind, .playPause)
        XCTAssertEqual(m.action(for: .back, in: .remote), .key(KeyCatalog.leftArrow))
        XCTAssertEqual(m.action(for: .tv, in: .remote), .key(KeyCatalog.rightArrow))
        XCTAssertEqual(m.action(for: .siri, in: .remote).kind, .toggleMode)
        XCTAssertEqual(m.action(for: .volumeUp, in: .remote).kind, .volumeUpFine)
        XCTAssertEqual(m.action(for: .volumeDown, in: .remote).kind, .volumeDownFine)
        XCTAssertEqual(m.action(for: .volumeUp, in: .trackpad).kind, .volumeUpFine)
    }

    func testMigrationMovesOldVolumeDefaultsToFine() {
        var m = ButtonMapping.defaults
        m.remote[.volumeUp] = RemoteAction(.volumeUp)
        m.remote[.volumeDown] = RemoteAction(.volumeDown)
        m.trackpad[.volumeUp] = RemoteAction(.volumeUp)
        m.trackpad[.volumeDown] = .key(KeyCatalog.downArrow)  // customised: must survive
        m.migrate(from: 1)
        XCTAssertEqual(m.remote[.volumeUp]?.kind, .volumeUpFine)
        XCTAssertEqual(m.remote[.volumeDown]?.kind, .volumeDownFine)
        XCTAssertEqual(m.trackpad[.volumeUp]?.kind, .volumeUpFine)
        XCTAssertEqual(m.trackpad[.volumeDown], .key(KeyCatalog.downArrow))

        var current = ButtonMapping.defaults
        current.remote[.volumeUp] = RemoteAction(.volumeUp)  // chosen deliberately after v2
        current.migrate(from: 2)
        XCTAssertEqual(current.remote[.volumeUp]?.kind, .volumeUp)
    }

    func testTrackpadModeDefaults() {
        let m = ButtonMapping.defaults
        for b in RemoteButton.allCases where b.isClickpad {
            XCTAssertEqual(m.action(for: b, in: .trackpad).kind, .leftClick, "\(b)")
        }
        XCTAssertEqual(m.action(for: .back, in: .trackpad).kind, .rightClick)
        XCTAssertEqual(m.action(for: .siri, in: .trackpad).kind, .toggleMode)
        XCTAssertEqual(m.action(for: .playPause, in: .trackpad).kind, .playPause)
    }

    func testCodableRoundTripUsesButtonNamesAsKeys() throws {
        var m = ButtonMapping.defaults
        m.set(.key(KeyCatalog.space, [.command, .shift]), for: .power, in: .trackpad)
        let data = try JSONEncoder().encode(m)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"playPause\""), json)
        let decoded = try JSONDecoder().decode(ButtonMapping.self, from: data)
        XCTAssertEqual(decoded, m)
        XCTAssertEqual(decoded.action(for: .power, in: .trackpad).shortcut?.displayString, "⇧⌘Space")
    }

    func testMissingEntriesFallBackToDefaults() {
        let m = ButtonMapping(remote: [:], trackpad: [:])
        XCTAssertEqual(m.action(for: .select, in: .remote).kind, .playPause)
        XCTAssertEqual(m.action(for: .select, in: .trackpad).kind, .leftClick)
    }

    func testRemoteDetectionRequiresClickpadDirections() {
        let remote = Set([0x42, 0x43, 0x44, 0x45, 0xCD].map { HIDUsage(page: 0x0C, usage: UInt32($0)) })
        XCTAssertTrue(SiriRemoteHID.looksLikeRemote(usages: remote))
        let keyboardMedia = Set([0xCD, 0xE9, 0xEA, 0xE2].map { HIDUsage(page: 0x0C, usage: UInt32($0)) })
        XCTAssertFalse(SiriRemoteHID.looksLikeRemote(usages: keyboardMedia))
    }
}

final class ClickpadRegionTests: XCTestCase {
    func testRegions() {
        XCTAssertEqual(SiriRemoteHID.clickpadButton(x: 0.5, y: 0.5), .select)
        XCTAssertEqual(SiriRemoteHID.clickpadButton(x: 0.6, y: 0.62), .select)
        XCTAssertEqual(SiriRemoteHID.clickpadButton(x: 0.5, y: 0.92), .up)
        XCTAssertEqual(SiriRemoteHID.clickpadButton(x: 0.5, y: 0.08), .down)
        XCTAssertEqual(SiriRemoteHID.clickpadButton(x: 0.08, y: 0.5), .left)
        XCTAssertEqual(SiriRemoteHID.clickpadButton(x: 0.92, y: 0.5), .right)
        XCTAssertEqual(SiriRemoteHID.clickpadButton(x: 0.85, y: 0.75), .right)
    }
}
