import AppKit
import SwiftUI
import WispProjectBrowserUI

@main
struct WispSciencePreview: App {
    @StateObject private var model = ProjectBrowserModel()

    var body: some Scene {
        WindowGroup("Wisp Science — 原生预览") {
            ProjectBrowserView(model: model)
                .frame(minWidth: 680, minHeight: 560)
                .task { await model.refresh() }
        }
        .defaultSize(width: 1120, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("选择数据库…") { model.chooseDatabase() }
                    .keyboardShortcut("o")
                    .disabled(model.isLoading)
            }
            CommandGroup(after: .newItem) {
                Button("刷新项目") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(model.isLoading)
            }
        }
    }
}
