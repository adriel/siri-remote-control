import AppKit
import Carbon
import CShims
import IOKit
import IOKit.hid
import RemoteCore

/// Looks for things on the system that can stop remote presses from working.
enum SystemInspector {
    struct HIDClient: Identifiable, Hashable {
        let pid: pid_t
        let name: String
        var interfaces: [String]
        var id: pid_t { pid }

        /// macOS processes that normally attach to the remote and don't interfere.
        var isSystem: Bool { ["WindowServer", "hidd", "BTLEServer", "corebrightnessd", "bluetoothd"].contains(name) }
    }

    struct ConflictingProcess: Identifiable, Hashable {
        let pid: pid_t
        let name: String
        let reason: String
        let canQuit: Bool
        var id: pid_t { pid }
    }

    struct EventTap: Identifiable, Hashable {
        let id: UInt32
        let pid: pid_t
        let processName: String
        let intercepts: [String]
        /// Owned by root or a system account (e.g. Screen Sharing's RFBEventHelperd), not a user app.
        let isSystem: Bool
    }

    // MARK: Processes holding the remote

    /// Every process with a user client on any of the remote's HID interfaces (or the touch surface beneath them).
    static func remoteClients(productIDs: Set<Int>) -> [HIDClient] {
        guard let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary? else { return [] }
        matching[kIOHIDVendorIDKey] = SiriRemoteHID.vendorID
        matching[kIOHIDTransportKey] = SiriRemoteHID.transport

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var clients: [pid_t: HIDClient] = [:]
        let ownPID = ProcessInfo.processInfo.processIdentifier
        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            let pid = property(device, kIOHIDProductIDKey) as? Int ?? 0
            guard productIDs.contains(pid) || SiriRemoteHID.knownModels[pid] != nil else { continue }
            let page = property(device, kIOHIDPrimaryUsagePageKey) as? Int ?? 0
            let usage = property(device, kIOHIDPrimaryUsageKey) as? Int ?? 0
            let interface = SiriRemoteHID.interfaceName(page: page, usage: usage)
            for creator in userClientCreators(below: device, depth: 0) {
                guard creator.pid != ownPID else { continue }
                var client = clients[creator.pid] ?? HIDClient(pid: creator.pid, name: creator.name, interfaces: [])
                if !client.interfaces.contains(interface) { client.interfaces.append(interface) }
                clients[creator.pid] = client
            }
        }
        return clients.values.sorted { ($0.isSystem ? 1 : 0, $0.name) < ($1.isSystem ? 1 : 0, $1.name) }
    }

    private static func userClientCreators(below entry: io_registry_entry_t, depth: Int) -> [(pid: pid_t, name: String)] {
        guard depth < 5 else { return [] }
        var result: [(pid_t, String)] = []
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &children) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(children) }
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            if let creator = property(child, "IOUserClientCreator") as? String, let parsed = parseCreator(creator) {
                result.append(parsed)
            }
            result += userClientCreators(below: child, depth: depth + 1)
        }
        return result
    }

    /// Parses "pid 91573, Remote Buddy".
    static func parseCreator(_ s: String) -> (pid: pid_t, name: String)? {
        guard s.hasPrefix("pid "), let comma = s.firstIndex(of: ",") else { return nil }
        guard let pid = pid_t(s[s.index(s.startIndex, offsetBy: 4)..<comma]) else { return nil }
        let name = s[s.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        return (pid, name)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    // MARK: Known conflicting apps

    private static let knownConflicts: [(process: String, reason: String)] = [
        ("Remote Buddy", "Grabs the Siri Remote exclusively. Quit it while using this app."),
        ("BetterTouchTool", "Can remap Siri Remote buttons and intercept key and mouse events."),
        ("karabiner_grabber", "Karabiner-Elements grabs HID devices and rewrites key events."),
        ("Karabiner-Core-Service", "Karabiner-Elements grabs HID devices and rewrites key events."),
        ("ControllerMate", "Can grab HID devices exclusively."),
        ("USB Overdrive", "Can grab HID devices and remap buttons."),
        ("SteerMouse", "Intercepts and rewrites mouse events."),
        ("Hammerspoon", "Scripts can intercept key and media events."),
        ("Keyboard Maestro Engine", "Macros can intercept keys and media keys."),
        ("Mac Media Key Forwarder", "Intercepts media keys and redirects them."),
        ("MediaKeyForwarder", "Intercepts media keys and redirects them."),
    ]

    static func conflictingProcesses() -> [ConflictingProcess] {
        var found: [ConflictingProcess] = []
        let gui = Dictionary(NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        for pid in allPIDs() {
            let name = executableName(pid)
            guard let match = knownConflicts.first(where: { $0.process == name }) else { continue }
            found.append(ConflictingProcess(pid: pid, name: gui[pid]?.localizedName ?? name, reason: match.reason, canQuit: gui[pid] != nil))
        }
        return found
    }

    static func quit(pid: pid_t) {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    // MARK: Secure input

    /// The process holding Secure Event Input (e.g. a focused password field), which blocks synthetic keystrokes.
    static func secureInputOwner() -> (pid: pid_t, name: String)? {
        guard IsSecureEventInputEnabled() else { return nil }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard let users = property(root, "IOConsoleUsers") as? [[String: Any]] else { return (0, "unknown process") }
        for user in users {
            if let pid = user["kCGSSessionSecureInputPID"] as? Int, pid > 0 {
                return (pid_t(pid), processName(pid_t(pid)))
            }
        }
        return (0, "unknown process")
    }

    // MARK: Event taps

    /// Active (non listen-only) event taps from other processes that can swallow or rewrite events.
    static func interceptingEventTaps() -> [EventTap] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return taps.prefix(Int(count)).compactMap { tap in
            guard tap.enabled, tap.options == .defaultTap, tap.tappingProcess != ownPID else { return nil }
            let mask = tap.eventsOfInterest
            var kinds: [String] = []
            if mask & (1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue) != 0 { kinds.append("keys") }
            if mask & (1 << CGEventType.leftMouseDown.rawValue | 1 << CGEventType.rightMouseDown.rawValue | 1 << CGEventType.mouseMoved.rawValue) != 0 { kinds.append("mouse") }
            if mask & (1 << CGEventType.scrollWheel.rawValue) != 0 { kinds.append("scroll") }
            if mask & (1 << 14) != 0 { kinds.append("media keys") } // NSEventTypeSystemDefined
            guard !kinds.isEmpty else { return nil }
            var uid: uid_t = 0
            let known = CShimProcInfo(tap.tappingProcess, nil, 0, &uid)
            return EventTap(id: tap.eventTapID, pid: tap.tappingProcess, processName: processName(tap.tappingProcess),
                            intercepts: kinds, isSystem: known && uid != getuid())
        }
    }

    // MARK: Process helpers

    static func processName(_ pid: pid_t) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName { return name }
        return executableName(pid)
    }

    private static func executableName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        if CShimProcName(pid, &buffer, UInt32(buffer.count)) > 0 { return String(cString: buffer) }
        // proc_name can't read other users' processes; sysctl can (16-character name).
        if CShimProcInfo(pid, &buffer, UInt32(buffer.count), nil), buffer[0] != 0 { return String(cString: buffer) }
        return "pid \(pid)"
    }

    private static func allPIDs() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(CShimListPids(&pids, Int32(pids.count)))
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }
}
