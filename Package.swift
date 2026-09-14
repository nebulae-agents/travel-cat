// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TravelCat",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TravelCore", targets: ["TravelCore"]),
        .library(name: "TravelStorage", targets: ["TravelStorage"]),
        .library(name: "TravelUI", targets: ["TravelUI"]),
        .executable(name: "TravelCatApp", targets: ["TravelCatApp"]),
        .executable(name: "travelcatctl", targets: ["TravelCatCLI"]),
    ],
    targets: [
        .target(name: "TravelCore"),
        .target(
            name: "TravelStorage",
            dependencies: ["TravelCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "TravelUI",
            dependencies: ["TravelCore", "TravelStorage"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "TravelCatApp",
            dependencies: ["TravelCore", "TravelStorage", "TravelUI"]
        ),
        .executableTarget(
            name: "TravelCatCLI",
            dependencies: ["TravelCore", "TravelStorage", "TravelUI"]
        ),
        .testTarget(name: "TravelCoreTests", dependencies: ["TravelCore"]),
        .testTarget(name: "TravelStorageTests", dependencies: ["TravelStorage"]),
        .testTarget(name: "TravelUITests", dependencies: ["TravelUI"]),
        .testTarget(
            name: "TravelCatAppTests",
            dependencies: ["TravelCatApp", "TravelUI", "TravelCore", "TravelStorage"]
        ),
    ]
)
