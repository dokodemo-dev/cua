// SPDX-License-Identifier: FSL-1.1-MIT

import CuaBotsServiceKit
#if os(iOS)
import SwiftUI

public struct ChatView: View {
    @ObservedObject private var model: PhoneModel
    private let bot: String
    @State private var text = ""
    @State private var showRoutines = false
    @State private var showArtifacts = false
    @FocusState private var composerFocused: Bool

    public init(model: PhoneModel, bot: String) {
        self.model = model
        self.bot = bot
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(model.turns) { turn in
                        TurnView(turn: turn)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.turns) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .overlay {
            if model.turns.isEmpty {
                ContentUnavailableView(
                    "まだ会話がありません",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("下の欄から \(bot) に頼んでください。")
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            composer
        }
        .navigationTitle(bot)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showRoutines = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("ルーティン")
                Button {
                    showArtifacts = true
                } label: {
                    Image(systemName: "folder")
                }
                .accessibilityLabel("ライブラリ")
            }
        }
        .task {
            model.open(bot: bot)
            model.startPolling(bot: bot)
        }
        .onDisappear {
            model.stopPolling()
        }
        .sheet(isPresented: $showRoutines) {
            RoutinesView(model: model, bot: bot)
        }
        .sheet(isPresented: $showArtifacts) {
            ArtifactsView(model: model, bot: bot)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("メッセージ", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .focused($composerFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.gray.opacity(0.14), in: RoundedRectangle(cornerRadius: 18))

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .disabled(!canSend)
            .accessibilityLabel("送信")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.busy
    }

    private func send() {
        let body = text
        text = ""
        Task {
            if await model.send(bot: bot, prompt: body) {
                composerFocused = true
            } else {
                text = body
            }
        }
    }
}

struct TurnView: View {
    let turn: Turn
    @State private var thinkingOpen = true

    private var parts: (thinking: String, answer: String) {
        TurnOutput.split(turn.output)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer(minLength: 40)
                Text(turn.prompt)
                    .font(.callout)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
                    .textSelection(.enabled)
            }

            if !parts.thinking.isEmpty {
                DisclosureGroup(isExpanded: $thinkingOpen) {
                    Text(parts.thinking)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                        .textSelection(.enabled)
                } label: {
                    Text("考えていること")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !parts.answer.isEmpty {
                MarkdownText(parts.answer)
            }

            switch turn.status {
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("作業しています…").font(.caption).foregroundStyle(.secondary)
                }
            case .failed:
                Text("うまくいきませんでした: \(turn.error ?? "unknown")")
                    .font(.caption)
                    .foregroundStyle(.red)
            case .done:
                EmptyView()
            }
        }
    }
}
#endif
