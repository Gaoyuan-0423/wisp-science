import SwiftUI
import WispProjectBrowser

struct NativeProvenanceView: View {
    let rows: [NativeProvenanceRow]
    var query = ""
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            if rows.isEmpty {
                Text("暂无工具调用").font(.headline)
                Text("工具调用的输入、输出和状态将在这里显示。").font(.caption).foregroundStyle(.secondary)
            } else {
                let filtered = rows.filter { $0.matches(query) }
                if filtered.isEmpty { Text("没有匹配的工具调用").foregroundStyle(.secondary) }
                ForEach(filtered) { row in NativeProvenanceRowView(row: row) }
            }
        }
    }
}
private struct NativeProvenanceRowView: View {
    let row: NativeProvenanceRow
    @State private var expanded: Bool?
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { expanded ?? row.initiallyExpanded }, set: { expanded = $0 })) {
            VStack(alignment: .leading, spacing: 8) {
                if !row.input.isEmpty { block("输入", row.input) }
                if !row.output.isEmpty { block("输出", row.output) }
            }.padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(2)
                Spacer(minLength: 4)
                Text(row.ok == true ? "成功" : row.ok == false ? "失败" : "进行中")
                    .font(.caption).foregroundStyle(row.ok == true ? .green : row.ok == false ? .red : .secondary)
            }
        }.padding(10).background(WispDesign.color("bg-elev", scheme), in: RoundedRectangle(cornerRadius: 8))
    }
    private func block(_ title: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(content).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
