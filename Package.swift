// swift-tools-version:5.9
import PackageDescription

// Embedding an Info.plist directly in __TEXT gives a command-line tool a
// bundle identity and a camera usage string. Without it TCC has nothing to
// show the user and the camera request fails silently instead of prompting.
func infoPlist(_ path: String) -> [LinkerSetting] {
    [.unsafeFlags([
        "-Xlinker", "-sectcreate",
        "-Xlinker", "__TEXT",
        "-Xlinker", "__info_plist",
        "-Xlinker", path,
    ])]
}

let package = Package(
    name: "MacID",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacIDCore", targets: ["MacIDCore"]),
        .executable(name: "macid-helper", targets: ["macid-helper"]),
        .executable(name: "MacIDApp", targets: ["MacIDApp"]),
    ],
    targets: [
        // Recognition, camera, storage, IPC and the lock-screen wiring.
        // Shared by the app and its privileged helper so the two can never
        // disagree about what counts as a match or where things live.
        .target(name: "MacIDCore", path: "core/Sources/MacIDCore"),

        // Root-only work: wiring and unwiring the lock screen. Ships inside
        // MacID.app, never on PATH. See helper/Sources/macid-helper/main.swift.
        .executableTarget(
            name: "macid-helper",
            dependencies: ["MacIDCore"],
            path: "helper/Sources/macid-helper",
            linkerSettings: infoPlist("helper/Resources/Info.plist")
        ),

        .executableTarget(
            name: "MacIDApp",
            dependencies: ["MacIDCore"],
            path: "app/Sources/MacIDApp",
            linkerSettings: infoPlist("app/Resources/Info.plist")
        ),
    ]
)
