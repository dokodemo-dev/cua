// SPDX-License-Identifier: FSL-1.1-MIT

import CuaBotsServiceUI
import SwiftUI

@main
struct CuaBotsApp: App {
    @StateObject private var model = PhoneModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
