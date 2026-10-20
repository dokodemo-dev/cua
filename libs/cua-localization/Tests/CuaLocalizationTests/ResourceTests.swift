// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.
import Foundation
import Testing

@testable import CuaLocalization

@Test func catalogsCanBeInstalledInsideAnAppInsteadOfTheBuildDirectory() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let resources = root.appendingPathComponent("Preview.app/Contents/Resources")
  try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
  let source = try #require(TranslationResources.bundle)
  let installed = resources.appendingPathComponent(TranslationResources.bundleName)
  try FileManager.default.copyItem(at: source.bundleURL, to: installed)
  let found = try #require(TranslationResources.find(in: [resources]))
  #expect(found.bundleURL.standardizedFileURL == installed.standardizedFileURL)
  let url = try #require(found.url(forResource: "ja", withExtension: "json"))
  let catalog = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
  #expect(catalog["New bot"] == "新しいBot")
}
