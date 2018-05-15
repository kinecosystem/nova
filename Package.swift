// swift-tools-version:4.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "stellarcmd",
    dependencies: [
      .package(url: "../kin-core-ios/KinSDK/StellarKit", from: "0.3.0"),
      .package(url: "../kin-core-ios/KinSDK/StellarKit/StellarKit/third-party/swift-sodium", from: "0.0.0"),
    ],
    targets: [
        .target(
            name: "stellarcmd",
            dependencies: ["Sodium", "StellarKit"]),
        .target(
            name: "nova",
            dependencies: ["Sodium", "StellarKit"]),
    ]
)
