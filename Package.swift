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
        .executable(name: "macid", targets: ["macid"]),
        .executable(name: "MacIDApp", targets: ["MacIDApp"]),
    ],
    targets: [
        // Recognition, camera, storage and IPC. Shared verbatim by the CLI
        // daemon and the menu bar app so the two can never disagree about
        // what counts as a match.
        .target(name: "MacIDCore", path: "core/Sources/MacIDCore"),

        .executableTarget(
            name: "macid",
            dependencies: ["MacIDCore"],
            path: "agent/Sources/macid",
            linkerSettings: infoPlist("agent/Resources/Info.plist")
        ),

        .executableTarget(
            name: "MacIDApp",
            dependencies: ["MacIDCore"],
            path: "app/Sources/MacIDApp",
            linkerSettings: infoPlist("app/Resources/Info.plist")
        ),
    ]
)
