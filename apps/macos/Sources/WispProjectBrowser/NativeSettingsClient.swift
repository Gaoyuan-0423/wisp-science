import Foundation

public enum SettingsValue: Codable, Equatable, Sendable {
    case object([String: SettingsValue]), array([SettingsValue]), string(String), integer(Int64), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let integer = try? value.decode(Int64.self) { self = .integer(integer) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([SettingsValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: SettingsValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .string(let v): try value.encode(v)
        case .integer(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    public subscript(_ key: String) -> SettingsValue {
        get { if case .object(let v) = self { return v[key] ?? .null }; return .null }
        set { var value = object; value[key] = newValue; self = .object(value) }
    }
    public var object: [String: SettingsValue] { if case .object(let value) = self { return value }; return [:] }
    public var array: [SettingsValue] { if case .array(let value) = self { return value }; return [] }
    public var string: String {
        switch self { case .string(let v): return v; case .integer(let v): return String(v); case .number(let v): return String(v); default: return "" }
    }
    public var bool: Bool { if case .bool(let v) = self { return v }; return false }
    public var decodedJSON: SettingsValue { (try? JSONDecoder().decode(SettingsValue.self, from: Data(string.utf8))) ?? .null }
    public var integer: Int64 { if case .integer(let v) = self { return v }; return Int64(string) ?? 0 }
}

public protocol NativeSettingsQuerying: Sendable {
    func invoke(_ command: String, args: [String: SettingsValue], projectID: String?) async throws -> SettingsValue
}

public actor NativeSettingsClient: NativeSettingsQuerying {
    public static let schema = "wisp.native-settings.v1"
    private let databaseURL: URL
    private let executableURL: URL?
    private var descriptor: Descriptor?
    private var process: Process?
    private var connecting: Task<Descriptor, Error>?

    public init(databaseURL: URL, executableURL: URL? = nil) {
        self.databaseURL = databaseURL
        self.executableURL = executableURL
    }

    public func invoke(_ command: String, args: [String: SettingsValue] = [:], projectID: String? = nil) async throws -> SettingsValue {
        let host = try await connect()
        // Mutations are never retried automatically: a lost reply can follow a
        // successful save. A later user refresh reconnects if the host restarted.
        do { return try await Self.request(host, command: command, args: args, projectID: projectID) }
        catch { descriptor = nil; throw error }
    }

    private func connect() async throws -> Descriptor {
        if let descriptor { return descriptor }
        if let connecting { return try await connecting.value }
        let task = Task { try await discoverOrLaunch() }
        connecting = task
        defer { connecting = nil }
        let host = try await task.value
        descriptor = host
        return host
    }

    private func readDescriptor() throws -> Descriptor {
        let file = databaseURL.deletingLastPathComponent().appendingPathComponent("native-settings.json")
        let result = try JSONDecoder().decode(Descriptor.self, from: Data(contentsOf: file))
        try Self.validate(result, databaseURL: databaseURL)
        return result
    }

    private func discoverOrLaunch() async throws -> Descriptor {
        if let host = try? readDescriptor(),
           (try? await Self.request(host, command: "native_settings_capabilities", args: [:], projectID: nil, timeout: 3)) != nil { return host }
        guard let executableURL, FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ProjectBrowserError.unavailable("找不到完整设置宿主。请使用最新构建脚本打包原生应用，或设置 WISP_DESKTOP_HOST_PATH 指向本仓库的 wisp-tauri。")
        }
        let child = Process()
        child.executableURL = executableURL
        child.arguments = ["--native-settings-host"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        for _ in 0..<60 {
            try Task.checkCancellation()
            if let host = try? readDescriptor(),
               (try? await Self.request(host, command: "native_settings_capabilities", args: [:], projectID: nil, timeout: 2)) != nil { return host }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw ProjectBrowserError.service("完整设置宿主未就绪。请确认当前数据库属于正在运行的桌面宿主，然后重试。")
    }

    struct Descriptor: Codable, Sendable {
        let schema: String
        let endpoint: String
        let token: String
        let database: String
        let pid: UInt32
    }

    static func validate(_ descriptor: Descriptor, databaseURL: URL) throws {
        guard descriptor.schema == schema, let endpoint = URL(string: descriptor.endpoint),
              endpoint.scheme == "http", endpoint.host == "127.0.0.1", endpoint.port != nil,
              endpoint.path == "/invoke", endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil, descriptor.token.count == 64,
              descriptor.token.allSatisfy({ $0.isHexDigit }),
              URL(fileURLWithPath: descriptor.database).resolvingSymlinksInPath().standardizedFileURL == databaseURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw ProjectBrowserError.invalidResponse
        }
    }

    private static let redirectGuard = NativeSettingsRedirectGuard()
    private static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
    }()

    private static func request(_ host: Descriptor, command: String, args: [String: SettingsValue], projectID: String?, timeout: TimeInterval = 665) async throws -> SettingsValue {
        let id = UUID().uuidString
        var request = URLRequest(url: URL(string: host.endpoint)!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(host.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: SettingsValue] = ["schema": .string(schema), "id": .string(id), "command": .string(command), "args": .object(args), "project_id": projectID.map(SettingsValue.string) ?? .null]
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await transport.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProjectBrowserError.service("设置宿主拒绝了请求，请刷新连接。") }
        return try decode(data, requestID: id)
    }

    static func decode(_ data: Data, requestID: String) throws -> SettingsValue {
        let response = try JSONDecoder().decode(SettingsValue.self, from: data)
        guard response["schema"].string == schema, response["id"].string == requestID else { throw ProjectBrowserError.invalidResponse }
        if case .string(let message) = response["error"] { throw ProjectBrowserError.service(message) }
        guard response.object.keys.contains("result") else { throw ProjectBrowserError.invalidResponse }
        return response["result"]
    }
}

private final class NativeSettingsRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
