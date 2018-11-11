// swift-tools-version:4.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "stellarcmd",
    dependencies: [
      .package(url: "../kin-core-ios/KinSDK/StellarKit", from: "0.9.0"),
      .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.7.0"),
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
