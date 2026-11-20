// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Observatory",
    platforms: [.macOS(.v14)],
    targets: [
        // Sources live directly under Observatory/; Tests/ is excluded from the app target.
        .executableTarget(name: "Observatory", path: ".", exclude: ["Tests"]),
        .testTarget(name: "ObservatoryTests", dependencies: ["Observatory"], path: "Tests"),
    ]
)
