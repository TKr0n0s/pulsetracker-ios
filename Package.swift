// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PulseTracker",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "PulseTracker", targets: ["PulseTracker"])],
    targets: [
        .target(
            name: "PulseTracker",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "PulseTrackerTests", dependencies: ["PulseTracker"]),
    ]
)
