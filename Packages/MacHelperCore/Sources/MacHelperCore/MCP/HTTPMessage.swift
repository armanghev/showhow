import Foundation

/// A minimal HTTP/1.1 request parser and response writer for the localhost MCP
/// endpoint. It only needs to understand what MCP clients send: a request line,
/// headers, and a Content-Length body.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public func header(_ name: String) -> String? { headers[name.lowercased()] }

    public enum ParseResult: Equatable {
        case complete(HTTPRequest, consumed: Int)
        case incomplete
        case invalid(String)
    }

    public static let maxBodyBytes = 8 * 1_048_576

    public static func parse(_ data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else {
            return data.count > 64 * 1024 ? .invalid("Headers too large") : .incomplete
        }
        guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid("Headers are not UTF-8")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid("Bad request line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return .invalid("Chunked bodies are not supported")
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBodyBytes else { return .invalid("Bad Content-Length") }
        let bodyStart = headerEnd.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= length else { return .incomplete }
        let bodyEnd = data.index(bodyStart, offsetBy: length)
        let request = HTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(data[bodyStart..<bodyEnd])
        )
        return .complete(request, consumed: data.distance(from: data.startIndex, to: bodyEnd))
    }
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: (try? value.encoded()) ?? Data())
    }

    public static func text(_ s: String, status: Int) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(s.utf8))
    }

    static let reasons: [Int: String] = [
        200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
        404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error",
    ]

    public func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = all["Connection"] ?? "keep-alive"
        for key in all.keys.sorted() { head += "\(key): \(all[key]!)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// Routes HTTP requests to the MCP core, enforcing the per-install token and
/// rejecting browser origins (DNS-rebinding protection for a localhost server).
public final class MCPHTTPRouter: @unchecked Sendable {
    public let core: MCPServerCore
    public let token: String

    public init(core: MCPServerCore, token: String) {
        self.core = core
        self.token = token
    }

    public func route(_ request: HTTPRequest) async -> HTTPResponse {
        if let origin = request.header("origin"), !Self.isLocalOrigin(origin) {
            return .text("Forbidden origin", status: 403)
        }
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        guard path == "/mcp" else { return .text("Not found", status: 404) }
        guard request.header("authorization") == "Bearer \(token)" else {
            return .text("Missing or wrong token. Copy the command from Mac Helper > Settings > Integrations.", status: 401)
        }
        switch request.method {
        case "POST":
            guard let message = try? JSONValue.decode(request.body) else {
                return .json(MCPServerCore.parseError(), status: 400)
            }
            if let response = await core.handle(message) {
                return .json(response)
            }
            return HTTPResponse(status: 202)
        case "GET":
            // No server-initiated stream; the spec allows 405 here.
            return HTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"])
        case "DELETE":
            return HTTPResponse(status: 204)
        default:
            return HTTPResponse(status: 405, headers: ["Allow": "POST, DELETE"])
        }
    }

    static func isLocalOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

/// `~/Library/Application Support/MacHelper/mcp.json`, read by the stdio bridge.
public struct MCPEndpointInfo: Codable, Equatable, Sendable {
    public var port: Int
    public var token: String
    public var url: String { "http://127.0.0.1:\(port)/mcp" }

    public init(port: Int, token: String) {
        self.port = port
        self.token = token
    }

    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/MacHelper/mcp.json")
    }

    public var claudeCodeCommand: String {
        "claude mcp add --transport http mac-helper \(url) --header \"Authorization: Bearer \(token)\""
    }
}

/// Adds or replaces the `mac-helper` entry in Claude Desktop's config, keeping
/// every other key as it was.
public enum ClaudeDesktopConfig {
    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    public static func merged(existing: Data?, bridgePath: String) throws -> JSONValue {
        var root: JSONValue = [:]
        if let existing, !existing.isEmpty {
            root = try JSONValue.decode(existing)
            guard root.objectValue != nil else { throw HandoffError("Claude Desktop's config is not a JSON object.") }
        }
        var servers = root["mcpServers"] ?? [:]
        if servers.objectValue == nil { servers = [:] }
        servers["mac-helper"] = ["command": .string(bridgePath), "args": []]
        root["mcpServers"] = servers
        return root
    }
}
