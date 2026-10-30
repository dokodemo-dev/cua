// SPDX-License-Identifier: FSL-1.1-MIT

#if os(iOS)
import CuaBotsServiceKit
import SwiftUI

public struct NewBotView: View {
    @ObservedObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = "violet"
    @State private var colorTouched = false
    @State private var spaceID = ""
    @State private var error: String?
    @State private var saving = false
    @FocusState private var nameFocused: Bool

    public init(model: PhoneModel) {
        self.model = model
    }

    private var problem: String? { BotName.problem(name) }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例: research", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($nameFocused)
                } header: {
                    Text("名前")
                } footer: {
                    if let problem, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text("半角小文字の英数字と . _ - が使えます（63文字まで）。")
                    }
                }

                Section("色") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(AvatarPalette.names, id: \.key) { item in
                            Button {
                                color = item.key
                                colorTouched = true
                            } label: {
                                Circle()
                                    .fill(AvatarPalette.face(item.key))
                                    .frame(width: 34, height: 34)
                                    .overlay {
                                        Circle()
                                            .strokeBorder(
                                                color == item.key ? Color.primary : Color.clear,
                                                lineWidth: 2
                                            )
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(item.label))
                            .accessibilityAddTraits(color == item.key ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Picker("Space", selection: $spaceID) {
                        Text("新しい Space をつくる（おすすめ）").tag("")
                        ForEach(model.spaces) { space in
                            Text(space.name.isEmpty ? space.id : space.name).tag(space.id)
                        }
                    }
                } header: {
                    Text("動かす場所")
                } footer: {
                    Text("既存の Space を選ぶと、その Space の信頼グループを引き継ぎます。")
                }

                if let error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("新しい Bot")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "作成中…" : "作成") {
                        Task { await create() }
                    }
                    .disabled(saving || problem != nil)
                }
            }
            .onAppear {
                nameFocused = true
            }
            .onChange(of: name) { _, value in
                if !colorTouched { color = Avatar.defaultColor(for: value) }
            }
        }
    }

    private func create() async {
        saving = true
        defer { saving = false }
        error = await model.createBot(
            name: name,
            color: color,
            spaceID: spaceID,
            createSpace: spaceID.isEmpty
        )
        if error == nil { dismiss() }
    }
}
#endif
