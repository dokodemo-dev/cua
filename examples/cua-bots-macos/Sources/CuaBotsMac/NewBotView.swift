// SPDX-License-Identifier: FSL-1.1-MIT
// Copyright (c) 2026 Cua AI, Inc.

import CuaBotsCore
import CuaBotsUI
import SwiftUI

/// Create a bot: meet it, give it a name and a look, and choose where its
/// computer runs and which agent drives it. It introduces itself once its
/// Space is up.
struct NewBotView: View {
    @EnvironmentObject var model: AppModel

    var step: Int { model.draft.step }
    var name: String { model.draft.name }
    var avatar: AvatarConfig { model.draft.avatar }

    var displayName: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? "your bot" : name }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            VStack(spacing: 22) {
                KoalaAvatar(avatar, mood: step == 2 ? .done : .idle)
                    .frame(width: 128, height: 128)
                    .id(avatar)
                    .transition(.move(edge: .trailing).combined(with: .scale))
                switch step {
                case 0: meet
                case 1: look
                default: whereItRuns
                }
            }
            .frame(maxWidth: 460)
            Spacer(minLength: 20)
            HStack {
                if step > 0 { Button(model.displayText("Back")) { withAnimation(.spring(response: 0.2)) { model.draft.step -= 1 } } }
                Spacer()
                stepDots
                Spacer()
                if step < 2 {
                    Button(model.displayText("Continue")) { withAnimation(.spring(response: 0.2)) { model.draft.step += 1 } }
                        .buttonStyle(.borderedProminent)
                        .disabled(step == 0 && name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(model.displayText("Create {name}", ["name": displayName])) {
                        model.createFromDraft()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.engine == nil)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(model.displayText("New bot"))
        .onChange(of: model.draft.name) { _, n in
            if !model.draft.customizedLook { model.draft.avatar.color = BotColor.default(for: n) }
        }
    }

    var meet: some View {
        VStack(spacing: 14) {
            Text(model.displayText("Meet your bot")).font(.title2.weight(.semibold))
            Text(model.displayText("A bot works on its own computer, keeps going while you're away, remembers what matters to you, and checks in when something needs your approval."))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            TextField(model.displayText("What should we call it?"), text: $model.draft.name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .multilineTextAlignment(.center)
                .onSubmit { if !name.isEmpty { withAnimation { model.draft.step = 1 } } }
        }
    }

    var look: some View {
        VStack(spacing: 14) {
            Text(model.displayText("Make {name} yours", ["name": displayName])).font(.title2.weight(.semibold))
            AvatarPicker(avatar: Binding(get: { model.draft.avatar },
                                         set: { model.draft.avatar = $0; model.draft.customizedLook = true }),
                         name: displayName)
        }
    }

    var whereItRuns: some View {
        Form {
            Picker(model.displayText("Its computer"), selection: $model.draft.placement) {
                ForEach(Placement.allCases) { p in Text(model.displayText(p.name)).tag(p) }
            }
            .pickerStyle(.segmented)
            HarnessSettings(harness: $model.draft.harness, runtime: $model.draft.runtime)
            LabeledContent(model.displayText("Memory")) {
                Text("Volume home · agents/\(Bot.agentName(for: displayName))").foregroundStyle(.secondary)
            }
            if model.draft.placement == .cloud {
                Text(model.displayText("A Cua Cloud Space is metered while it runs.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
    }

    var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Circle().fill(i == step ? Color.primary : Color.secondary.opacity(0.3)).frame(width: 6, height: 6)
            }
        }
    }
}
