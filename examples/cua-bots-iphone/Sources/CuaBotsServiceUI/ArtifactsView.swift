// SPDX-License-Identifier: FSL-1.1-MIT

#if os(iOS)
import CuaBotsServiceKit
import SwiftUI

public struct ArtifactsView: View {
    @ObservedObject private var model: PhoneModel
    private let bot: String
    @Environment(\.dismiss) private var dismiss

    public init(model: PhoneModel, bot: String) {
        self.model = model
        self.bot = bot
    }

    public var body: some View {
        NavigationStack {
            List {
                if model.artifacts.isEmpty {
                    ContentUnavailableView(
                        "成果物がありません",
                        systemImage: "folder",
                        description: Text("Bot がファイルを作り、成果物として登録すると、ここに出ます。")
                    )
                } else {
                    ForEach(model.artifacts) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.name).font(.body.weight(.medium))
                            Text("\(row.ownerBotID)・\(Format.bytes(row.byteCount))・\(Format.dateTime(row.createdAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !row.sha256.isEmpty {
                                Text("sha256 \(String(row.sha256.prefix(12)))…")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("ライブラリ")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .refreshable { await model.refreshArtifacts(bot: bot) }
            .task { await model.refreshArtifacts(bot: bot) }
        }
    }
}
#endif
