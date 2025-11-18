// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "hdrplay",
    platforms: [
        .iOS(.v14),
        .tvOS(.v14),
        .macOS(.v11)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "hdrplay",
            targets: ["hdrplay"]
        ),
    ],
    targets: [
        .binaryTarget(name: "libavformat", path: "Frameworks/xcframework/libavformat.xcframework"),
        .binaryTarget(name: "libavcodec", path: "Frameworks/xcframework/libavcodec.xcframework"),
        .binaryTarget(name: "libavutil", path: "Frameworks/xcframework/libavutil.xcframework"),
        .binaryTarget(name: "libswresample", path: "Frameworks/xcframework/libswresample.xcframework"),
        .binaryTarget(name: "libswscale", path: "Frameworks/xcframework/libswscale.xcframework"),
        .target(
                    name: "CFFmpeg",
                    dependencies: ["libavformat", "libavcodec", "libavutil", "libswresample", "libswscale"],
                    path: "Sources/CFFmpeg"
                ),
        .target(
            name: "hdrplay",
            dependencies: ["CFFmpeg"],
            path: "Sources/hdrplay"
        ),
        .testTarget(
            name: "hdrplayTests",
            dependencies: ["hdrplay"]
        ),
    ]
)
