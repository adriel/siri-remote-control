// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RemoteControl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RemoteControl", targets: ["RemoteControl"]),
    ],
    targets: [
        // C shim around the private MultitouchSupport framework (loaded with dlopen) and libproc.
        .target(name: "CShims", path: "Sources/CShims"),
        // Pure logic: buttons, actions, mappings, HID usage table, touch gesture recognition.
        .target(name: "RemoteCore", path: "Sources/RemoteCore"),
        // The menu bar app.
        .executableTarget(
            name: "RemoteControl",
            dependencies: ["CShims", "RemoteCore"],
            path: "Sources/RemoteControl",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"], path: "Tests/RemoteCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
