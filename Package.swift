// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import MachO
import PackageDescription

let ffmpegPrefix = "/opt/homebrew/opt/ffmpeg"

/// Swift Build leaves out, on every other build, the flag that loads swift-testing's macros, and
/// `@Test` then fails to expand. So the tests name the plugin themselves, from the toolchain whose
/// PackageDescription runs this manifest.
let testingMacros: [SwiftSetting] = {
    let api = "/lib/swift/pm/ManifestAPI/libPackageDescription.dylib"
    let images = (0..<_dyld_image_count()).compactMap { _dyld_get_image_name($0).map { String(cString: $0) } }
    guard let usr = images.first(where: { $0.hasSuffix(api) }).map({ String($0.dropLast(api.count)) }) else { return [] }
    let plugins = usr + "/lib/swift/host/plugins/testing"
    let server = usr + "/bin/swift-plugin-server"
    guard FileManager.default.fileExists(atPath: plugins), FileManager.default.fileExists(atPath: server) else { return [] }
    return [.unsafeFlags(["-external-plugin-path", plugins + "#" + server])]
}()

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
        .target(
            name: "Captions",
            dependencies: ["BonboriPluginKit"],
            path: "Sources/Plugins/Captions"
        ),
        .target(
            name: "DataBroadcasting",
            dependencies: ["BonboriPluginKit"],
            path: "Sources/Plugins/DataBroadcasting"
        ),
        .testTarget(
            name: "CaptionsTests",
            dependencies: ["Captions"],
            path: "Tests/CaptionsTests",
            swiftSettings: testingMacros
        ),
        .testTarget(
            name: "DataBroadcastingTests",
            dependencies: ["DataBroadcasting"],
            path: "Tests/DataBroadcastingTests",
            swiftSettings: testingMacros
        ),
        .executableTarget(
            name: "Bonbori",
            dependencies: ["TVCore", "BonboriPluginKit", "Jikkyo", "Captions", "DataBroadcasting"],
            path: "Sources/Bonbori"
        ),
    ]
)
