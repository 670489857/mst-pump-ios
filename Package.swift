// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MstPump",
    platforms: [.iOS(.v15), .macOS(.v11)],
    products: [
        .library(name: "PumpKit", targets: ["PumpKit"])
    ],
    targets: [
        .target(name: "PumpKit", path: "Sources/PumpKit"),
        .testTarget(name: "PumpKitTests", dependencies: ["PumpKit"], path: "Tests/PumpKitTests")
    ]
)
