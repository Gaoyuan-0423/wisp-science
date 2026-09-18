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
                    laneView(lane)
                }
            }.padding(10).background(WispDesign.color("bg-sunken", scheme), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func laneView(_ lane: String) -> some View {
        let title = lane == "input" ? "输入" : lane == "model" ? "模型" : "工具"
        let laneSegments = segments.filter { $0.lane == lane }
        return HStack(spacing: 10) {
            Text(title).font(.caption).frame(width: 36, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(WispDesign.color("border", scheme)).frame(height: 1)
                    ForEach(laneSegments) { segment in
                        segmentButton(segment, width: geometry.size.width)
                    }
                }.frame(height: 18)
            }.frame(height: 18)
        }
    }

    private func segmentButton(_ segment: NativeTrajectorySegment, width: CGFloat) -> some View {
        let lane = segment.lane == "tools" ? "tool" : segment.lane
        let fill = WispDesign.color("traj-\(lane)-bar", scheme)
        let border = selected == segment.key ? WispDesign.color("clay", scheme) : Color.clear
        let label = rows.first { $0.id == segment.key }?.cell.summary ?? segment.key
        let barWidth = max(CGFloat(1), width * CGFloat(segment.width_pct) / 100 - 2)
        let offset = width * CGFloat(segment.left_pct) / 100
        return Button { select(segment.key) } label: {
            RoundedRectangle(cornerRadius: 3).fill(fill)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(border, lineWidth: 2))
        }.buttonStyle(.plain)
            .frame(width: barWidth, height: 12)
            .offset(x: offset)
            .accessibilityLabel(label)
            .help(label)
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
