// swift-tools-version:4.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "nova",
    dependencies: [
      .package(url: "https://github.com/avi-kik/StellarKit.git", from: "0.9.0"),
      .package(url: "https://github.com/jedisct1/swift-sodium.git", from: "0.7.0"),
      .package(url: "https://github.com/1024jp/GzipSwift", from: "4.1.0"),
      .package(url: "https://github.com/ashevin/YACLP.git", from: "0.0.1"),
    ],
    targets: [
        .target(
            name: "nova",
            dependencies: ["Sodium", "StellarKit", "Gzip", "YACLP"]),
    ]
)
