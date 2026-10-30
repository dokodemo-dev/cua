// SPDX-License-Identifier: FSL-1.1-MIT

#if os(iOS)
import SwiftUI

public struct RootView: View {
    @ObservedObject private var model: PhoneModel
    @State private var path: [String] = []

    public init(model: PhoneModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if model.isSignedIn {
                NavigationStack(path: $path) {
                    BotListView(model: model)
                        .navigationDestination(for: String.self) { bot in
                            ChatView(model: model, bot: bot)
                        }
                }
            } else {
                SignInView(model: model)
            }
        }
        .preferredColorScheme(model.theme.scheme)
        .onOpenURL { url in
            Task { _ = await model.signIn(link: url.absoluteString) }
        }
        .alert(
            "エラー",
            isPresented: Binding(
                get: { model.error != nil },
                set: { if !$0 { model.error = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}
#endif
