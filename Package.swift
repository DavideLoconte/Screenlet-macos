// swift-tools-version:6.0
// Screenlet. build-app.sh packages it as Screenlet.app.
import PackageDescription

let package = Package(
    name: "Screenlet",
    platforms: [.macOS(.v15)],
    targets: [
        // Objective-C for CGVirtualDisplay (private, declared by hand) and IOUSBHost.
        .target(name: "Native", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("IOUSBHost")]),
        .executableTarget(
            name: "Screenlet",
            dependencies: ["Native"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ScreenletTests", dependencies: ["Screenlet"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
