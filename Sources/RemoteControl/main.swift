import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
        app.setActivationPolicy(.prohibited)
        Snapshots.run(outputDirectory: arguments[index + 1])
        exit(0)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
