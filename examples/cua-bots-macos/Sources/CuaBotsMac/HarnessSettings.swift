// SPDX-License-Identifier: FSL-1.1-MIT
import CuaBotsCore
import SwiftUI

struct HarnessSettings: View {
  @EnvironmentObject var model: AppModel
  @Binding var harness: Harness
  @Binding var runtime: BotRuntime

  var body: some View {
    Picker("Agent", selection: $harness) {
      ForEach(model.harnesses) { entry in Text(entry.name).tag(entry.harness) }
      if !model.harnesses.contains(where: { $0.id == harness.id }) {
        Text("\(harness.name) (saved ID)").tag(harness)
      }
    }
    TextField("Model (blank: harness default)", text: $runtime.model)
    TextField("Guest working directory (blank: bot home)", text: $runtime.workingDirectory)
    if harness == .pi {
      TextField("Pi provider (blank: configured default)", text: $runtime.provider)
      TextField(
        "Guest Pi agent directory (blank: isolated bot config)", text: $runtime.piAgentDirectory)
      TextField("Additional system prompt", text: $runtime.systemPrompt, axis: .vertical)
        .lineLimit(2...5)
      Text(
        "Skills, extensions, custom tools and models.json are read from the guest Pi directory. No Mac settings or keys are copied."
      )
      .font(.caption).foregroundStyle(.secondary)
      Text(
        "Custom Pi endpoints must support OpenAI Chat Completions. Anthropic wire format is not supported by the SDK Pi adapter."
      )
      .font(.caption).foregroundStyle(.secondary)
    }
    Text(
      "Use a bot-owned working directory. The app manages its instructions, memory, outputs and Pi prompt/model defaults; other Pi project settings are preserved."
    )
    .font(.caption).foregroundStyle(.secondary)
  }
}

struct HarnessSettingsSheet: View {
  @EnvironmentObject var model: AppModel
  @Environment(\.dismiss) var dismiss
  var bot: Bot
  @State private var harness: Harness
  @State private var runtime: BotRuntime
  @State private var saving = false
  @State private var error: String?

  init(bot: Bot) {
    self.bot = bot
    _harness = State(initialValue: bot.harness)
    _runtime = State(initialValue: bot.runtime ?? BotRuntime())
  }

  var body: some View {
    VStack(alignment: .leading) {
      Text("Agent settings for \(bot.name)").font(.headline)
      Form { HarnessSettings(harness: $harness, runtime: $runtime) }
        .formStyle(.grouped)
      Text(
        "Saving stops the old session. Your computer, conversation and memory stay; the next message starts a new agent session."
      )
      .font(.caption).foregroundStyle(.secondary)
      if let error { Text(error).foregroundStyle(.red) }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.disabled(saving)
        Button("Save") {
          saving = true
          Task {
            if await model.store.configure(bot.id, harness: harness, runtime: runtime) {
              dismiss()
            } else {
              error = model.store.lastError
            }
            saving = false
          }
        }.disabled(saving || model.store.isBusy(bot.id))
      }
    }
    .padding(20).frame(width: 520, height: 500)
  }
}
