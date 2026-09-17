import Foundation

public struct ProjectSummary: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let workspaceDirectory: String
    public let starred: Bool
    public let sessionCount: Int64
    public let artifactCount: Int64
    public let updatedAt: Int64
    public let runningCount: Int64
    public let needsYouCount: Int64
    public let syncConfigured: Bool
    public let lastSyncedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id, name, description, starred
        case workspaceDirectory = "workspace_dir"
        case sessionCount = "session_count"
        case artifactCount = "artifact_count"
        case updatedAt = "updated_at"
        case runningCount = "running_count"
        case needsYouCount = "needs_you_count"
        case syncConfigured = "sync_configured"
        case lastSyncedAt = "last_synced_at"
    }
}

public struct ProjectListSnapshot: Sendable {
    public let projects: [ProjectSummary]
    public let activitySource: String
}

public enum ProjectBrowserError: LocalizedError {
    case unavailable(String)
    case service(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message), .service(let message): return message
        case .invalidResponse: return "查询服务返回了不兼容的数据，请重新构建原生预览版。"
        }
    }
}

/// Matches `wisp-dto::project_browser`; the shared JSON fixture tests this boundary.
public struct ProjectBrowserClient: Sendable {
    public static let schema = "wisp.project-browser.v1"
    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    public func listProjects(databaseURL: URL) async throws -> ProjectListSnapshot {
        // One short-lived process per refresh: closing stdin ends the service.
        // Blocking pipe reads run off the UI thread and the process has a deadline.
        try await Task.detached(priority: .userInitiated) {
            try query(databaseURL: databaseURL)
        }.value
    }

    private func query(databaseURL: URL) throws -> ProjectListSnapshot {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ProjectBrowserError.unavailable("找不到查询服务。请使用 scripts/build_native_macos.sh 构建应用。")
        }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--database", databaseURL.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Write the small request before launch so an immediate startup failure
        // cannot race this write with a closed pipe.
        let requestID = "projects-1"
        let request = ["schema": Self.schema, "id": requestID, "type": "list_projects"]
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        try process.run()
        let deadline = DispatchSource.makeTimerSource(queue: .global())
        deadline.schedule(deadline: .now() + 30)
        deadline.setEventHandler {
            if process.isRunning { process.terminate() }
        }
        deadline.resume()
        defer {
            deadline.cancel()
            if process.isRunning { process.terminate() }
        }
        let reply = output.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: diagnostics, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProjectBrowserError.service(message.isEmpty ? "查询服务已停止或超时，请重试。" : message)
        }
        return try Self.decode(reply, requestID: requestID)
    }

    static func decode(_ data: Data, requestID: String) throws -> ProjectListSnapshot {
        let response: Response
        do { response = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw ProjectBrowserError.invalidResponse }
        guard response.schema == schema, response.id == requestID else {
            throw ProjectBrowserError.invalidResponse
        }
        if response.type == "error" {
            throw ProjectBrowserError.service(response.message ?? "项目查询失败。")
        }
        guard response.type == "projects", let projects = response.projects,
              response.activitySource == "persisted_only" else {
            throw ProjectBrowserError.invalidResponse
        }
        return ProjectListSnapshot(projects: projects, activitySource: "persisted_only")
    }

    private struct Response: Decodable {
        let schema: String
        let id: String?
        let type: String
        let projects: [ProjectSummary]?
        let activitySource: String?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case schema, id, type, projects, message
            case activitySource = "activity_source"
        }
    }
}
