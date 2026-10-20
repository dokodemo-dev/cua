// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.
import SwiftUI

public struct LanguagePicker: View {
  @Binding private var preference: String
  public init(preference: Binding<String>) { _preference = preference }
  public var body: some View {
    let t = Translator(preference: preference)
    Picker(t.text("Language"), selection: $preference) {
      Text(t.text("System")).tag("system")
      Text("日本語").tag("ja")
      Text("English").tag("en")
    }
    .accessibilityIdentifier("display-language")
  }
}
