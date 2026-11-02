// swift-tools-version:6.0
// Screenlet. build-app.sh packages it as Screenlet.app.
import PackageDescription

let package = Package(
    name: "Screenlet",
    platforms: [.macOS(.v15)],
    targets: [
        // Objective-C interface bridging private CGVirtualDisplay APIs and IOUSBHost.
        .target(name: "Native", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("IOUSBHost")]),
        .executableTarget(
            name: "Screenlet",
            dependencies: ["Native"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ScreenletTests", dependencies: ["Screenlet"], resources: [.copy("Resources/vectors.json")], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
