import SwiftUI
import WispProjectBrowser

/// ACP authentication's bounded scrollback, using the host-owned PTY. Input is
/// never persisted by this view; no shell-launch API is exposed by settings.
struct NativeAuthTerminal: View {
    @ObservedObject var model: NativeSettingsModel
    let sessionID: String
    let close: () -> Void
    @State private var output = ""
    @State private var input = ""
    @State private var running = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("授权终端")).fontWeight(.semibold)
            ScrollView { Text(output).font(WispDesign.font(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 260).padding(10).background(Color.black.opacity(0.04))
            HStack {
                SecureField(localized("输入后按发送（内容不保存在设置中）"), text: $input).textFieldStyle(NativeSettingsTextFieldStyle()).onSubmit { send(input + "\r"); input = "" }
                Button(localized("发送")) { send(input + "\r"); input = "" }.disabled(!running)
                Button(localized("中断")) { send("\u{03}") }.disabled(!running)
                Button(localized("关闭")) { Task { _ = await model.run("close_terminal", ["sessionId": .string(sessionID)], refresh: false, success: "授权终端已关闭"); close() } }
            }
        }.task(id: sessionID) {
            let project = model.projectID
            while !Task.isCancelled {
                do {
                    let snapshot = try await model.client.invoke("native_terminal_snapshot", args: ["sessionId": .string(sessionID)], projectID: project)
                    guard !Task.isCancelled else { break }
                    // Strip terminal control sequences; preserve the printable
                    // auth URLs and prompts without interpreting executable links.
                    output = snapshot["text"].string.replacingOccurrences(of: "\\x1B\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
                    running = snapshot["running"].bool
                    if !running { break }
                    try await Task.sleep(nanoseconds: 750_000_000)
                } catch { if !Task.isCancelled { model.error = error.localizedDescription }; break }
            }
        }
    }
    private func send(_ text: String) { Task { _ = await model.run("write_terminal", ["sessionId": .string(sessionID), "data": .string(text)], refresh: false, success: "") } }
}
