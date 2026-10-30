// SPDX-License-Identifier: FSL-1.1-MIT

#if os(iOS)

import CuaBotsServiceKit
import SwiftUI

public struct BotListView: View {
    @ObservedObject private var model: PhoneModel
    @State private var showSettings = false
    @State private var showNew = false

    public init(model: PhoneModel) {
        self.model = model
    }

    private var pinned: [String] { model.pins.filter { model.bots.contains($0) } }
    private var rest: [String] { model.bots.filter { !model.pins.contains($0) } }

    public var body: some View {
        List {
            if let notice = model.notice {
                Section {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !pinned.isEmpty {
                Section("ピン留め") {
                    ForEach(pinned, id: \.self) { bot in
                        row(bot)
                    }
                }
            }

            Section {
                if model.bots.isEmpty {
                    ContentUnavailableView(
                        "Bot がありません",
                        systemImage: "person.2.slash",
                        description: Text("Web の画面から Bot を作ってください。")
                    )
                } else {
                    ForEach(rest, id: \.self) { bot in
                        row(bot)
                    }
                }
            }

            if !model.archived.isEmpty {
                Section("アーカイブ") {
                    ForEach(model.archived, id: \.self) { bot in
                        HStack(spacing: 12) {
                            BotAvatar(avatar: model.avatars[bot], name: bot)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bot)
                                Text(model.spaceLabel(for: bot))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .opacity(0.6)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Bots")
        .toolbar {
            if model.isAdministrator {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showNew = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新しい Bot")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("設定")
            }
        }
        .refreshable { await model.refreshBots() }
        .task { await model.refreshBots() }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .sheet(isPresented: $showNew) {
            NewBotView(model: model)
        }
    }

    @ViewBuilder
    private func row(_ bot: String) -> some View {
        NavigationLink(value: bot) {
            HStack(spacing: 12) {
                BotAvatar(avatar: model.avatars[bot], name: bot)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot).font(.body.weight(.medium))
                    Text(model.spaceLabel(for: bot))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .swipeActions(edge: .leading) {
            Button {
                Task { await model.setPinned(bot, pinned: !model.isPinned(bot)) }
            } label: {
                Label(
                    model.isPinned(bot) ? "ピン留めを外す" : "ピン留め",
                    systemImage: model.isPinned(bot) ? "pin.slash" : "pin"
                )
            }
            .tint(.orange)
        }
        .contextMenu {
            Button {
                Task { await model.setPinned(bot, pinned: !model.isPinned(bot)) }
            } label: {
                Label(
                    model.isPinned(bot) ? "ピン留めを外す" : "ピン留め",
                    systemImage: model.isPinned(bot) ? "pin.slash" : "pin"
                )
            }
        }
    }
}
#endif
