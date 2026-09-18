import Foundation

public enum NativeTrajectoryAxis: String, Codable, CaseIterable, Sendable {
    case duration, turns, calls
}
public struct NativeTrajectoryRow: Identifiable, Sendable {
    public let id: String
    public let turn: Int64
    public let cell: NativeTrajectoryCell
    public static func collect(_ turns: [NativeTrajectoryTurn], query: String = "") -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return turns.flatMap { turn in
            turn.cells.enumerated().compactMap { index, cell in
                cell.matches(query) ? Self(id: "\(turn.index):\(index)", turn: turn.index, cell: cell) : nil
            }
        }
    }
}
public struct NativeTrajectorySegment: Codable, Equatable, Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let lane: String
    public let left_pct: Double
    public let width_pct: Double
    /// Same sequential packing as the WebView timeline. Unknown durations use a
    /// display weight; these widths are not measured wall-clock timestamps.
    public static func collect(_ rows: [NativeTrajectoryRow], axis: NativeTrajectoryAxis) -> [Self] {
        let events = rows.filter { $0.cell.kind != "usage" }
        guard !events.isEmpty else { return [] }
        func segment(_ row: NativeTrajectoryRow, _ left: Double, _ width: Double) -> Self {
            Self(key: row.id, lane: row.cell.kind == "user" ? "input" : row.cell.kind == "tool" ? "tools" : "model", left_pct: left, width_pct: width)
        }
        if axis == .turns {
            var groups: [[NativeTrajectoryRow]] = []
            for row in events {
                if groups.last?.last?.turn == row.turn { groups[groups.count - 1].append(row) }
                else { groups.append([row]) }
            }
            let column = 100 / Double(groups.count)
            return groups.enumerated().flatMap { group, rows in
                rows.enumerated().map { index, row in segment(row, Double(group) * column + Double(index) * column / Double(rows.count), column / Double(rows.count)) }
            }
        }
        var weights = events.map { Double(max(0, $0.cell.duration_ms ?? 0)) }
        let positive = weights.filter { $0 > 0 }
        if axis == .calls || positive.isEmpty { weights = events.map { _ in 1 } }
        else {
            let floor = max(1, positive.reduce(0, +) / Double(positive.count) * 0.5)
            weights = weights.map { $0 > 0 ? $0 : floor }
        }
        let total = max(1, weights.reduce(0, +))
        var accumulated = 0.0
        return events.enumerated().map { index, row in
            let left = accumulated / total * 100; accumulated += weights[index]
            return segment(row, left, weights[index] / total * 100)
        }
    }
}
public struct NativeTrajectoryTiming: Equatable, Sendable {
    public let input: Double
    public let model: Double
    public let tools: Double
    public var total: Double { input + model + tools }
    public static func collect(_ cells: [NativeTrajectoryCell]) -> Self? {
        let starts = cells.compactMap { $0.ts.map(Double.init) }
        let ends = cells.compactMap { cell in cell.ts.map { Double($0) + Double(cell.duration_ms ?? 0) } }
        guard let start = starts.min(), let end = ends.max(), end > start else { return nil }
        let model = cells.filter { $0.kind == "assistant" }.reduce(0.0) { $0 + Double($1.duration_ms ?? 0) }
        let tools = cells.filter { $0.kind == "tool" }.reduce(0.0) { $0 + Double($1.duration_ms ?? 0) }
        return Self(input: max(0, end - start - model - tools), model: max(0, model), tools: max(0, tools))
    }
}
