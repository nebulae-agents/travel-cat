// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AgentXAppSDK", platforms: [.macOS(.v13)], products: [.library(name: "AgentXAppSDK", targets: ["AgentXAppSDK"])], targets: [.target(name: "AgentXAppSDK"), .testTarget(name: "AgentXAppSDKTests", dependencies: ["AgentXAppSDK"])])
