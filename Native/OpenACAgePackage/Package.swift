// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "OpenACAgeSwift",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "OpenACAgeSwift", targets: ["OpenACAgeSwift"]),
    ],
    targets: [
        .binaryTarget(
            name: "openac_age_mobile_appFFI",
            url: "https://github.com/bonds-tw/backupTW-iOS/releases/download/openac-age-v1/OpenACAgeBindings.xcframework.zip",
            checksum: "9eb080736b4aa73211a8ba1bdc057955edda8d430a0ac9e088e5aa31c4ac76f4"),
        .target(
            name: "OpenACAgeSwift",
            dependencies: ["openac_age_mobile_appFFI", "COpenACAgeFFI"],
            path: "Sources/OpenACAgeSwift",
            linkerSettings: [.linkedLibrary("c++")]),
        // Xcode 26 does not expose the module map of a static-library
        // XCFramework to Swift. Register the binary header as a real Clang
        // module so UniFFI's generated Swift can import its C declarations.
        .target(
            name: "COpenACAgeFFI",
            dependencies: ["openac_age_mobile_appFFI"],
            path: "Sources/COpenACAgeFFI",
            publicHeadersPath: "include"),
    ])
