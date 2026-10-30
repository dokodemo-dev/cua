// swift-tools-version: 6.0
// SPDX-License-Identifier: FSL-1.1-MIT

import PackageDescription

// The iPhone client for cua-bots-service (the Go service on the VPS).
//
// It is deliberately independent of the Mac app and of the Rust SDK: a phone
// talks to the service's HTTP API over the VPN, so there is no Cua FFI,
// framework, or screen stream to link. That keeps a device build limited to
// signing.
let package = Package(
    name: "CuaBotsService",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CuaBotsServiceKit", targets: ["CuaBotsServiceKit"]),
        .library(name: "CuaBotsServiceUI", targets: ["CuaBotsServiceUI"]),
    ],
    targets: [
        .target(name: "CuaBotsServiceKit", path: "Sources/CuaBotsServiceKit"),
        .target(
            name: "CuaBotsServiceUI",
            dependencies: ["CuaBotsServiceKit"],
            path: "Sources/CuaBotsServiceUI"
        ),
        .testTarget(
            name: "CuaBotsServiceKitTests",
            dependencies: ["CuaBotsServiceKit"],
            path: "Tests/CuaBotsServiceKitTests"
        ),
    ]
)
