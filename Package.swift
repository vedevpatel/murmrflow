// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Murmrflow",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Murmrflow", path: "Sources/Murmrflow")
    ]
)
