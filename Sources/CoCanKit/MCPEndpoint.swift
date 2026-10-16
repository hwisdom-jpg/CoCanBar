import Foundation

/// 官方 MCP 地址：`https://mcp.thecandysign.com/<PSN>/<token>/mcp`。
///
/// 小程序「龙虾服务」按所选的接入模型给出 `/sse` 或 `/mcp` 结尾的地址，token 是同一个；
/// 这里只走 Streamable HTTP，`/sse` 统一换成 `/mcp`。
///
/// token 就在路径里，整条地址都按密钥处理：只存钥匙串，界面和日志只显示 `redacted`。
/// 只接受官方主机，避免把 token 发到别的服务器。
public struct MCPEndpoint: Sendable, Equatable {
    public static let host = "mcp.thecandysign.com"

    public let url: URL
    public let psn: String
    let token: String

    public init?(string raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == Self.host,
              components.port == nil || components.port == 443,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil
        else { return nil }

        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2] == "mcp" || parts[2] == "sse",
              Self.isPSN(parts[0]), Self.isToken(parts[1]),
              let url = URL(string: "https://\(Self.host)/\(parts[0])/\(parts[1])/mcp")
        else { return nil }

        self.url = url
        self.psn = parts[0]
        self.token = parts[1]
    }

    /// 不含 token 的展示形式。
    public var redacted: String { "https://\(Self.host)/\(psn)/••••/mcp" }

    /// 把文本里的完整地址和 token 换掉，用于显示服务端返回的文字。
    public func redact(_ text: String) -> String {
        text.replacingOccurrences(of: url.absoluteString, with: redacted)
            .replacingOccurrences(of: token, with: "••••")
    }

    /// 从任意文本里提取 MCP 地址，按 PSN 去重，保留首次出现的顺序。
    /// 小程序「龙虾服务」复制出来的是一整段安装提示，里面的 `…/<PSN>/SKILL.md` 不算地址。
    public static func extractAll(from text: String) -> [MCPEndpoint] {
        let pattern = #"https://mcp\.thecandysign\.com/[0-9]{8,24}/[A-Za-z0-9_\-]{4,128}/(?:mcp|sse)(?![A-Za-z0-9_\-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        var result: [MCPEndpoint] = []
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text),
                  let endpoint = MCPEndpoint(string: String(text[r])),
                  seen.insert(endpoint.psn).inserted
            else { continue }
            result.append(endpoint)
        }
        return result
    }

    static func isPSN(_ s: String) -> Bool {
        (8...24).contains(s.count) && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func isToken(_ s: String) -> Bool {
        (4...128).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
