// SPDX-License-Identifier: FSL-1.1-MIT

#if os(iOS)
import CuaBotsServiceKit
import SwiftUI

public struct RoutinesView: View {
    @ObservedObject private var model: PhoneModel
    private let bot: String
    @Environment(\.dismiss) private var dismiss
    @State private var showAdd = false

    public init(model: PhoneModel, bot: String) {
        self.model = model
        self.bot = bot
    }

    public var body: some View {
        NavigationStack {
            List {
                if model.routines.isEmpty {
                    ContentUnavailableView(
                        "ルーティンがありません",
                        systemImage: "clock",
                        description: Text("決めた時刻に Bot が自分から動きます。")
                    )
                } else {
                    ForEach(model.routines) { job in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(job.title).font(.body.weight(.medium))
                                Text("\(Format.interval(job.everySec))ごと・次回 \(Format.relative(job.nextRunAt))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: binding(for: job)).labelsHidden()
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await model.deleteRoutine(bot: bot, job: job) }
                            } label: {
                                Label("削除", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("ルーティン")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAdd = true
                    } label: {
                        Label("追加", systemImage: "plus")
                    }
                }
            }
            .refreshable { await model.refreshRoutines(bot: bot) }
            .task { await model.refreshRoutines(bot: bot) }
            .sheet(isPresented: $showAdd) {
                AddRoutineView(model: model, bot: bot)
            }
        }
    }

    private func binding(for job: Routine) -> Binding<Bool> {
        Binding(
            get: { !job.paused },
            set: { running in
                Task { await model.setRoutine(bot: bot, job: job, paused: !running) }
            }
        )
    }
}

struct AddRoutineView: View {
    @ObservedObject var model: PhoneModel
    let bot: String
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var prompt = ""
    @State private var every = 86_400
    @State private var delay = 3_600
    @State private var saving = false

    private let intervals = [(900, "15分ごと"), (3_600, "1時間ごと"), (21_600, "6時間ごと"),
                             (86_400, "1日ごと"), (604_800, "1週間ごと")]
    private let delays = [(0, "すぐ"), (300, "5分後"), (3_600, "1時間後"), (43_200, "12時間後")]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名前（例: 朝のまとめ）", text: $title)
                    TextField("頼むこと（例: 昨夜の変更を要約して）", text: $prompt, axis: .vertical)
                        .lineLimit(3...6)
                }
                Section {
                    Picker("間隔", selection: $every) {
                        ForEach(intervals, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
                    }
                    Picker("最初の実行", selection: $delay) {
                        ForEach(delays, id: \.0) { value, label in
                            Text(label).tag(value)
                        }
                    }
                }
                if let error = model.error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("ルーティンを追加")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "追加中…" : "追加") {
                        Task {
                            saving = true
                            let ok = await model.addRoutine(
                                bot: bot,
                                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                                everySec: every,
                                delaySec: delay
                            )
                            saving = false
                            if ok { dismiss() }
                        }
                    }
                    .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty
                        || prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
#endif
