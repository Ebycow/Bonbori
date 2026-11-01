// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-2.0-or-later
import PackageDescription

let ffmpegPrefix = "/opt/homebrew/opt/ffmpeg"

let package = Package(
    name: "Bonbori",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Bonbori", targets: ["Bonbori"]),
        .executable(name: "tvprobe", targets: ["tvprobe"]),
    ],
    targets: [
        .target(
            name: "TVCore",
            path: "Sources/TVCore",
            cSettings: [
                .unsafeFlags(["-I\(ffmpegPrefix)/include", "-O2", "-Wall", "-Wno-deprecated-declarations"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(ffmpegPrefix)/lib", "-Xlinker", "-rpath", "-Xlinker", "\(ffmpegPrefix)/lib"]),
                .linkedLibrary("avcodec"),
                .linkedLibrary("avfilter"),
                .linkedLibrary("avutil"),
                .linkedLibrary("swresample"),
                .linkedLibrary("swscale"),
                .linkedLibrary("iconv"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .executableTarget(
            name: "tvprobe",
            dependencies: ["TVCore"],
            path: "Sources/tvprobe"
        ),
        // What plugins can see of the app.
        .target(
            name: "BonboriPluginKit",
            path: "Sources/BonboriPluginKit"
        ),
        .target(
            name: "Jikkyo",
            dependencies: ["BonboriPluginKit"],
            path: "Sources/Plugins/Jikkyo"
        ),
        .executableTarget(
            name: "Bonbori",
            dependencies: ["TVCore", "BonboriPluginKit", "Jikkyo"],
            path: "Sources/Bonbori"
        ),
    ]
)
