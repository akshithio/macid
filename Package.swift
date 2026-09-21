// swift-tools-version:5.9
import PackageDescription

// Embeds an Info.plist in __TEXT so TCC can show the camera prompt.
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
    dependencies: [
        // Auto-updates via an EdDSA-signed appcast.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "MacIDCore", path: "core"),

        .executableTarget(
            name: "macid-helper",
            dependencies: ["MacIDCore"],
            path: "helper",
            exclude: ["Info.plist"],
            linkerSettings: infoPlist("helper/Info.plist")
        ),

        .executableTarget(
            name: "MacIDApp",
            dependencies: ["MacIDCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "app",
            exclude: ["Resources"],
            linkerSettings: infoPlist("app/Resources/Info.plist") + [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
    ]
)
