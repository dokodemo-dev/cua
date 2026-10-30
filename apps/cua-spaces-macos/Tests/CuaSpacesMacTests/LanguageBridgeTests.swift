// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.
import Foundation
import Testing

@testable import CuaSpacesMacKit

@Suite("Display language bridge")
@MainActor
struct LanguageBridgeTests {
  @Test func nativeAndWebShareOneValidatedPreference() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("ui-language.json")
    func make() -> AppModel {
      AppModel(
        backend: FixtureSpacesBackend(), keyvault: KeyvaultModel(client: nil),
        onboarding: OnboardingModel(statePath: root.appendingPathComponent("onboarding.json").path),
        settingsPath: root.appendingPathComponent("settings.json").path,
        telemetry: FixtureTelemetry(), languageFileURL: file)
    }
    let model = make()
    let bridge = WebUIBridge(model: model, allowedOrigins: [])
    let result =
      try await bridge.handle("settings.choose", ["row": "language", "option": "ja"])
      as? [String: Any]
    #expect(result?["language"] as? String == "ja")
    #expect(model.displayText("Settings") == "設定")
    #expect(make().languagePreference == "ja")
    await #expect(throws: (any Error).self) {
      _ = try await bridge.handle("settings.choose", ["row": "language", "option": "invalid"])
    }
    #expect(make().languagePreference == "ja")
    try model.setDisplayLanguage("en")
    #expect(bridge.settings()["language"] as? String == "en")
  }
}
