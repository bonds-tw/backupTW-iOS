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
            dependencies: ["openac_age_mobile_appFFI"],
            path: "Sources/OpenACAgeSwift"),
    ])
