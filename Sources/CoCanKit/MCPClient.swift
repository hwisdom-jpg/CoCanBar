import Foundation

public struct MCPTool: Sendable, Equatable {
    public let name: String
    public let description: String
    /// 工具参数的 JSON Schema（服务端没给时为空）。
    public let inputSchema: JSONValue?
}

public enum MCPError: Error, LocalizedError, Sendable, Equatable {
    case unauthorized
    case http(Int)
    case network(String)
    case rpc(code: Int, message: String)
    case tool(String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "MCP token 无效或已失效，请在小程序「龙虾服务」重新复制"
        case .http(let code): return "MCP 服务返回 HTTP \(code)"
        case .network(let message): return "MCP 网络错误：\(message)"
        case .rpc(let code, let message): return "MCP 错误 \(code)：\(message)"
        case .tool(let message): return "设备返回错误：\(message)"
        case .badResponse(let message): return "MCP 响应异常：\(message)"
        }
    }
}

/// 官方 MCP（Streamable HTTP 传输，协议 2025-06-18）的最小客户端。
///
/// 流程：`initialize` 拿到 `Mcp-Session-Id` → `notifications/initialized` → `tools/call`。
/// 会话过期（HTTP 404）时重新握手一次。地址里有 token：错误信息不带地址，服务端返回的文字先脱敏，也不跟随重定向。
public actor MCPClient {
    public static let clientProtocolVersion = "2025-06-18"

    private let endpoint: MCPEndpoint
    private let session: URLSession
    private let redirectGuard = RefuseRedirects()
    private let clientVersion: String
    private var sessionID: String?
    private var protocolVersion: String?
    private var nextID = 1
    private var initTask: Task<Void, Error>?
    /// 每次 `reset()` 加 1：旧一代的握手结果不再写回，同一代会话过期时只重新握手一次。
    private var generation = 0

    public init(endpoint: MCPEndpoint, clientVersion: String = "0.2.0", timeout: TimeInterval = 20) {
        self.endpoint = endpoint
        self.clientVersion = clientVersion
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        session = URLSession(configuration: config)
    }

    public nonisolated var psn: String { endpoint.psn }

    public func listTools() async throws -> [MCPTool] {
        let result = try await request("tools/list", params: .object([:]))
        guard let tools = result["tools"]?.arrayValue else { throw MCPError.badResponse("tools/list 缺少 tools") }
        return tools.compactMap { tool in
            guard let name = tool["name"]?.stringValue else { return nil }
            return MCPTool(name: name, description: tool["description"]?.stringValue ?? "",
                           inputSchema: tool["inputSchema"])
        }
    }

    /// 调用工具，返回文本内容（多个 text 块用换行拼接）。
    public func callTool(_ name: String, arguments: [String: JSONValue] = [:]) async throws -> String {
        let result = try await request("tools/call", params: .object([
            "name": .string(name),
            "arguments": .object(arguments),
        ]))
        let text = (result["content"]?.arrayValue ?? [])
            .compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
            .joined(separator: "\n")
        if result["isError"]?.boolValue == true {
            throw MCPError.tool(text.isEmpty ? "工具返回错误" : displayText(text))
        }
        // 有些工具用 {"success": false} 表示失败
        if let object = JSONValue.parse(text)?.objectValue,
           object["success"]?.boolValue == false || object["ok"]?.boolValue == false {
            throw MCPError.tool(displayText(text))
        }
        return text
    }

    /// 调用工具并把返回文本按 JSON 解析。
    public func callToolJSON(_ name: String, arguments: [String: JSONValue] = [:]) async throws -> JSONValue {
        let text = try await callTool(name, arguments: arguments)
        guard let value = JSONValue.parse(text) else { throw MCPError.badResponse("\(name) 返回的不是 JSON") }
        return value
    }

    /// 丢弃当前会话，下次调用时重新握手。
    public func reset() {
        generation += 1
        sessionID = nil
        protocolVersion = nil
        initTask = nil
    }

    /// 服务端返回的文字先脱敏再截断，才放进错误信息。
    private func displayText(_ text: String) -> String {
        String(endpoint.redact(text).prefix(300))
    }

    private func rpcError(_ error: JSONValue, fallback: String) -> MCPError {
        .rpc(code: error["code"]?.intValue ?? 0, message: error["message"]?.stringValue.map(displayText) ?? fallback)
    }

    // MARK: - 会话

    private func ensureInitialized() async throws {
        while true {
            let current = generation
            let task: Task<Void, Error>
            if let existing = initTask {
                task = existing
            } else {
                task = Task { try await self.initializeSession(generation: current) }
                initTask = task
            }
            do {
                try await task.value
            } catch {
                if initTask == task { initTask = nil }
                if generation == current { throw error }
                continue
            }
            // 等待期间被 reset 过，就按新一代重新握手
            if generation == current { return }
        }
    }

    private func initializeSession(generation expected: Int) async throws {
        let reply = try await post(method: "initialize", params: .object([
            "protocolVersion": .string(Self.clientProtocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("CoCanBar"), "version": .string(clientVersion)]),
        ]), sessionID: nil, protocolVersion: nil, expectsResponse: true)
        guard let message = reply.message else { throw MCPError.badResponse("initialize 没有返回内容") }
        if let error = message["error"] { throw rpcError(error, fallback: "握手失败") }
        let negotiated = message["result"]?["protocolVersion"]?.stringValue
        guard generation == expected else { return }
        _ = try await post(method: "notifications/initialized", params: nil,
                           sessionID: reply.sessionID, protocolVersion: negotiated, expectsResponse: false)
        // 发完 initialized 通知才启用会话；期间被 reset 的话这次结果作废
        guard generation == expected else { return }
        protocolVersion = negotiated
        sessionID = reply.sessionID
    }

    private func request(_ method: String, params: JSONValue) async throws -> JSONValue {
        try await ensureInitialized()
        let used = generation
        do {
            return try await requestOnce(method, params: params)
        } catch MCPError.http(404) {
            // 会话过期：同一代会话只重新握手一次，并发的请求共用这次握手
            if generation == used { reset() }
            try await ensureInitialized()
            return try await requestOnce(method, params: params)
        }
    }

    private func requestOnce(_ method: String, params: JSONValue) async throws -> JSONValue {
        let reply = try await post(method: method, params: params, sessionID: sessionID,
                                   protocolVersion: protocolVersion, expectsResponse: true)
        guard let message = reply.message else { throw MCPError.badResponse("\(method) 没有收到对应的响应") }
        if let error = message["error"] { throw rpcError(error, fallback: "未知错误") }
        guard let result = message["result"] else { throw MCPError.badResponse("\(method) 缺少 result") }
        return result
    }

    // MARK: - 传输

    private struct Reply: Sendable {
        let message: JSONValue?
        let sessionID: String?
    }

    private func post(method: String, params: JSONValue?, sessionID: String?, protocolVersion: String?,
                      expectsResponse: Bool) async throws -> Reply {
        var body: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let params { body["params"] = params }
        var requestID: Int?
        if expectsResponse {
            requestID = nextID
            body["id"] = .number(Double(nextID))
            nextID += 1
        }

        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(protocolVersion ?? Self.clientProtocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))

        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: redirectGuard)
            // SSE 流不一定会自己关闭，拿到需要的响应就结束这个请求
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw MCPError.badResponse("不是 HTTP 响应") }
            switch http.statusCode {
            case 200, 202: break
            case 401, 403: throw MCPError.unauthorized
            default: throw MCPError.http(http.statusCode)
            }

            let newSessionID = http.value(forHTTPHeaderField: "Mcp-Session-Id")
            guard let requestID else { return Reply(message: nil, sessionID: newSessionID) }

            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let message: JSONValue?
            if contentType.contains("text/event-stream") {
                message = try await readEventStream(bytes, id: requestID)
            } else {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                message = try Self.parseBody(data, id: requestID)
            }
            return Reply(message: message, sessionID: newSessionID)
        } catch let error as MCPError {
            throw error
        } catch let error as URLError {
            throw MCPError.network(NetworkErrorText.describe(error))
        } catch {
            throw MCPError.network("请求失败")
        }
    }

    /// 边收边解析 SSE，读到 id 对得上的消息就返回，不等连接关闭。
    private func readEventStream(_ bytes: URLSession.AsyncBytes, id: Int) async throws -> JSONValue? {
        var parser = SSEParser()
        var line: [UInt8] = []
        var lastWasCR = false
        for try await byte in bytes {
            // 行尾可能是 \n、\r 或 \r\n
            if byte == 0x0A, lastWasCR {
                lastWasCR = false
                continue
            }
            lastWasCR = byte == 0x0D
            guard byte == 0x0A || byte == 0x0D else {
                line.append(byte)
                continue
            }
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            if let data = parser.feed(text), let message = Self.match(JSONValue.parse(data), id: id) {
                return message
            }
        }
        if !line.isEmpty { _ = parser.feed(String(decoding: line, as: UTF8.self)) }
        return parser.flush().flatMap { Self.match(JSONValue.parse($0), id: id) }
    }

    static func parseBody(_ data: Data, id: Int) throws -> JSONValue? {
        let text = String(decoding: data, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 有的服务端返回 SSE 却没标 Content-Type
        if trimmed.hasPrefix("event:") || trimmed.hasPrefix("data:") || trimmed.hasPrefix(":") {
            return parseSSE(text).lazy.compactMap { match($0, id: id) }.first
        }
        guard let value = JSONValue.parse(trimmed) else { throw MCPError.badResponse("无法解析返回内容") }
        return match(value, id: id)
    }

    /// 在一条消息（或批量数组）里找 id 对得上的响应，不拿别的消息顶替。
    /// id 为 null 的错误响应（服务端没认出请求 id）按这次请求的错误处理。
    static func match(_ value: JSONValue?, id: Int) -> JSONValue? {
        guard let value else { return nil }
        let messages = value.arrayValue ?? [value]
        if let exact = messages.first(where: { idMatches($0["id"], id) }) { return exact }
        return messages.first { $0["id"] == JSONValue.null && $0["error"] != nil }
    }

    static func idMatches(_ value: JSONValue?, _ id: Int) -> Bool {
        switch value {
        case .number(let number)?: return number == Double(id)
        case .string(let string)?: return string == String(id)
        default: return false
        }
    }

    /// 解析完整的 SSE 文本：每个事件的 data 行拼起来按 JSON 解析。
    static func parseSSE(_ text: String) -> [JSONValue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var parser = SSEParser()
        var events: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let data = parser.feed(String(line)) { events.append(data) }
        }
        if let data = parser.flush() { events.append(data) }
        return events.compactMap(JSONValue.parse)
    }
}

/// SSE 增量解析：一行一行喂入，遇到空行时返回这个事件拼好的 data。
struct SSEParser {
    private var dataLines: [String] = []

    mutating func feed(_ line: String) -> String? {
        if line.isEmpty { return flush() }
        if line.hasPrefix("data:") {
            var value = line.dropFirst(5)
            if value.hasPrefix(" ") { value = value.dropFirst() }
            dataLines.append(String(value))
        }
        return nil
    }

    mutating func flush() -> String? {
        defer { dataLines.removeAll() }
        return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
    }
}

/// 不跟随重定向：MCP 地址里有 token，请求只发给官方地址本身，3xx 按 HTTP 错误处理。
final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
