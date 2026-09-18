import SwiftUI
import WispProjectBrowser

struct NativeTrajectoryChart: View {
    let rows: [NativeTrajectoryRow]
    let axis: NativeTrajectoryAxis
    let selected: String?
    let select: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    private var segments: [NativeTrajectorySegment] { NativeTrajectorySegment.collect(rows, axis: axis) }
    var body: some View {
        if !segments.isEmpty {
            VStack(spacing: 6) {
                ForEach(["input", "model", "tools"], id: \.self) { lane in
                    HStack(spacing: 10) {
                        Text(lane == "input" ? "输入" : lane == "model" ? "模型" : "工具").font(.caption).frame(width: 36, alignment: .leading)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(WispDesign.color("border", scheme)).frame(height: 1)
                                ForEach(segments.filter { $0.lane == lane }) { segment in
                                    Button { select(segment.key) } label: {
                                        RoundedRectangle(cornerRadius: 3).fill(WispDesign.color("traj-\(lane == "tools" ? "tool" : lane)-bar", scheme))
                                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selected == segment.key ? WispDesign.color("clay", scheme) : .clear, lineWidth: 2))
                                    }.buttonStyle(.plain)
                                        .frame(width: max(1, geometry.size.width * segment.width_pct / 100 - 2), height: 12)
                                        .offset(x: geometry.size.width * segment.left_pct / 100)
                                        .accessibilityLabel(rows.first { $0.id == segment.key }?.cell.summary ?? segment.key)
                                        .help(rows.first { $0.id == segment.key }?.cell.summary ?? segment.key)
                                }
                            }.frame(height: 18)
                        }.frame(height: 18)
                    }
                }
            }.padding(10).background(WispDesign.color("bg-sunken", scheme), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
struct NativeTrajectoryTurnBar: View {
    let timing: NativeTrajectoryTiming
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Rectangle().fill(WispDesign.color("traj-input-bar", scheme)).frame(width: geometry.size.width * timing.input / timing.total)
                Rectangle().fill(WispDesign.color("traj-model-bar", scheme)).frame(width: geometry.size.width * timing.model / timing.total)
                Rectangle().fill(WispDesign.color("traj-tool-bar", scheme)).frame(width: geometry.size.width * timing.tools / timing.total)
            }.clipShape(Capsule())
        }.frame(height: 5).help("输入 \(String(format: "%.0f", timing.input)) ms · 模型 \(String(format: "%.0f", timing.model)) ms · 工具 \(String(format: "%.0f", timing.tools)) ms")
    }
}
