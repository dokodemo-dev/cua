// SPDX-License-Identifier: FSL-1.1-MIT

#if os(iOS)
import CuaBotsServiceKit
import SwiftUI

public struct SettingsView: View {
    @ObservedObject private var model: PhoneModel
    @Environment(\.dismiss) private var dismiss

    public init(model: PhoneModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("接続先") {
                    Text(model.endpoint?.baseURL.absoluteString ?? "-")
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }

                if let session = model.session {
                    Section("セッション") {
                        LabeledContent("種類", value: session.role == "administrator" ? "管理者" : "Bot（\(session.botID)）")
                        LabeledContent("できること", value: session.capabilities.joined(separator: ", "))
                        if let expires = session.expiresAt {
                            LabeledContent("有効期限", value: Format.dateTime(expires))
                        }
                    }
                }

                Section("表示") {
                    Picker("テーマ", selection: $model.theme) {
                        ForEach(ThemePreference.allCases, id: \.self) { pref in
                            Text(pref.label).tag(pref)
                        }
                    }
                }

                Section {
                    Button("サインアウト", role: .destructive) {
                        model.signOut()
                        dismiss()
                    }
                } footer: {
                    Text("資格情報はこの端末の Keychain から消えます。入り直すには cua-bots-open のリンクが必要です。")
                }
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
#endif
