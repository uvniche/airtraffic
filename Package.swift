// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "airtraffic",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "airtraffic", targets: ["airtraffic"]),
    ],
    targets: [
        .executableTarget(
            name: "airtraffic",
            path: "Sources/airtraffic"
        ),
    ]
)
