// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.
import CuaLocalization
import SwiftUI

struct LanguageSettingsView: View {
  @EnvironmentObject var model: AppModel
  @State private var failure: String?
  var body: some View {
    Form {
      LanguagePicker(
        preference: Binding(
          get: { model.languagePreference },
          set: { value in
            do {
              try model.setDisplayLanguage(value)
              failure = nil
            } catch { failure = error.localizedDescription }
          }))
      Text(model.displayText("Language settings apply to the interface, not agent replies."))
        .font(.caption).foregroundStyle(.secondary)
      if let failure { Text(failure).foregroundStyle(.red) }
    }
    .padding(20).frame(width: 420)
  }
}
