// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.
import Foundation
import Testing

@testable import CuaLocalization

@Test func languageResolutionAndFallback() {
  #expect(DisplayLanguage.resolve("system", preferred: ["ja-JP", "en"]) == "ja")
  #expect(DisplayLanguage.resolve("system", preferred: ["fr-FR", "ja"]) == "en")
  #expect(DisplayLanguage.resolve("en", preferred: ["ja"]) == "en")
  #expect(DisplayLanguage.resolve("invalid", preferred: ["ja"]) == "ja")
  #expect(Translator(preference: "ja").text("New bot") == "新しいBot")
  #expect(Translator(preference: "ja").text("Untranslated text") == "Untranslated text")
  #expect(Translator(preference: "ja").text("Create {name}", ["name": "demo"]) == "demoを作成")
  #expect(Translator(preference: "ja").text("Show in menu bar") == "メニューバーに表示")
  #expect(
    Translator(preference: "ja").text("Set by {source}.", ["source": "CUA_SPACES_DEFAULT_LOCATION"])
      == "CUA_SPACES_DEFAULT_LOCATIONで設定されています。"
  )
}

@Test func preferencePersistenceIsIsolatedAndValidated() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appendingPathComponent("ui-language.json")
  #expect(DisplayLanguage.load(from: file) == "system")
  try DisplayLanguage.save("ja", to: file)
  #expect(DisplayLanguage.load(from: file) == "ja")
  #expect(throws: (any Error).self) { try DisplayLanguage.save("invalid", to: file) }
  #expect(DisplayLanguage.load(from: file) == "ja")
  try Data("not json".utf8).write(to: file)
  #expect(DisplayLanguage.load(from: file) == "system")
}
