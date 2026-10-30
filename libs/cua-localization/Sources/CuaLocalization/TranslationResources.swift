// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.
import Foundation

/// The same installed-resource search as CuaSpacesMacKit.ModuleResources.
/// SwiftPM's generated accessor doesn't search a signed app's Contents/Resources.
enum TranslationResources {
  static let bundleName = "CuaLocalization_CuaLocalization.bundle"
  static let bundle: Bundle? = {
    let main = Bundle.main
    let code = Bundle(for: Marker.self)
    return find(
      in: [
        main.resourceURL,
        main.bundleURL,
        main.executableURL?.deletingLastPathComponent(),
        code.resourceURL,
        code.bundleURL,
        code.bundleURL.deletingLastPathComponent(),
      ].compactMap { $0 })
  }()

  static func find(in directories: [URL]) -> Bundle? {
    directories.lazy.compactMap {
      Bundle(url: $0.appendingPathComponent(bundleName, isDirectory: true))
    }.first
  }

  private final class Marker {}
}
