// SPDX-License-Identifier: FSL-1.1-MIT

#if os(iOS)

import CuaBotsServiceKit
import SwiftUI

public struct SignInView: View {
    @ObservedObject private var model: PhoneModel
    @State private var link = ""
    @State private var showManual = false
    // Prefilled with the service's VPN name: the certificate the service
    // presents carries this name and nothing else (the VPN CA's name
    // constraints rule out an IP address), so typing an address is the
    // exceptional case now.
    @State private var base = ServiceEndpoint.defaultBase
    @State private var credential = ""
    @State private var working = false
    @FocusState private var credentialFocused: Bool

    public init(model: PhoneModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("cua-bots-open のリンク", text: $link, axis: .vertical)
                        .lineLimit(2...5)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.footnote.monospaced())
                } header: {
                    Text("リンクを貼る")
                } footer: {
                    Text("リンクには接続先と資格情報が入っています。VPN に入った状態で接続してください。")
                }

                Section {
                    Button {
                        Task {
                            working = true
                            _ = await model.signIn(link: link)
                            working = false
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if working {
                                ProgressView()
                            } else {
                                Text("接続").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(working || link.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section {
                    DisclosureGroup("接続先と資格情報を分けて入れる", isExpanded: $showManual) {
                        TextField(ServiceEndpoint.defaultBase, text: $base)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField("資格情報", text: $credential, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.footnote.monospaced())
                            .focused($credentialFocused)
                        Button("この内容で接続") {
                            Task {
                                working = true
                                _ = await model.signIn(base: base, credential: credential)
                                working = false
                            }
                        }
                        .disabled(working || base.isEmpty || credential.isEmpty)
                    }
                }

                if let error = model.error {
                    Section {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                }

                Section {
                    Text("サービスは VPN の中にあります。iPhone が WireGuard に入っていないと届きません。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Cua Bots")
            .onChange(of: model.prefilledBase) { _, value in
                guard let value, !value.isEmpty else { return }
                base = value
                showManual = true
                credentialFocused = true
            }
        }
    }
}
#endif
