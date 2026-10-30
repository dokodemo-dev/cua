// swift-tools-version: 6.0
// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.
import PackageDescription

let package = Package(
  name: "CuaLocalization",
  platforms: [.macOS(.v14), .iOS(.v18)],
  products: [.library(name: "CuaLocalization", targets: ["CuaLocalization"])],
  targets: [
    .target(name: "CuaLocalization", resources: [.process("Resources")]),
    .testTarget(name: "CuaLocalizationTests", dependencies: ["CuaLocalization"]),
  ]
)
