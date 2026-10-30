// swift-tools-version: 6.0
// SPDX-License-Identifier: FSL-1.1-MIT
import PackageDescription

// Copied to an isolated temporary package by scripts/test.sh --core-only.
let package = Package(
  name: "CuaBotsCoreCheck",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "CuaBotsCore"),
    .target(name: "CuaBotsUI", dependencies: ["CuaBotsCore"]),
    .testTarget(name: "CuaBotsCoreTests", dependencies: ["CuaBotsCore", "CuaBotsUI"]),
  ],
  swiftLanguageModes: [.v5]
)
