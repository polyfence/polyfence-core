// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PolyfenceCore",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "PolyfenceCore",
            targets: ["PolyfenceCore"]
        )
    ],
    targets: [
        .target(
            name: "PolyfenceCore",
            path: "ios/Classes"
        )
    ]
)
