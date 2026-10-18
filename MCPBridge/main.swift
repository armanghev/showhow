// showhow-mcp: a tiny stdio-to-HTTP bridge for Claude Desktop.
//
// Claude Desktop starts local MCP servers as stdio commands. This bridge reads
// newline-delimited JSON-RPC from stdin, forwards each message to ShowHow's
// Streamable HTTP endpoint on 127.0.0.1 (port and token from
// ~/Library/Application Support/ShowHow/mcp.json), and writes responses to
// stdout. If ShowHow is not running it tries to launch it once.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ShowHowCore

let bundleID = "com.armanghev.ShowHow"

func log(_ message: String) {
    FileHandle.standardError.write(Data("showhow-mcp: \(message)\n".utf8))
}

func writeLine(_ value: JSONValue) {
    var data = (try? value.encoded()) ?? Data()
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func loadEndpoint() -> MCPEndpointInfo? {
    guard let data = try? Data(contentsOf: MCPEndpointInfo.defaultURL()) else { return nil }
    return try? JSONDecoder().decode(MCPEndpointInfo.self, from: data)
}

var launchedApp = false

func launchAppIfNeeded() {
    guard !launchedApp else { return }
    launchedApp = true
    #if os(macOS)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-g", "-b", bundleID]
    try? task.run()
    task.waitUntilExit()
    Thread.sleep(forTimeInterval: 2.5)
    #endif
}

final class ResultBox: @unchecked Sendable {
    var value: Result<(Int, Data), Error> = .failure(URLError(.unknown))
}

func post(_ body: Data, to endpoint: MCPEndpointInfo) -> Result<(Int, Data), Error> {
    var request = URLRequest(url: URL(string: endpoint.url)!, timeoutInterval: 600)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
    request.httpBody = body
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox()
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error {
            box.value = .failure(error)
        } else {
            box.value = .success(((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
        }
        semaphore.signal()
    }.resume()
    semaphore.wait()
    return box.value
}

func errorResponse(id: JSONValue?, message: String) -> JSONValue {
    ["jsonrpc": "2.0", "id": id ?? .null, "error": ["code": -32000, "message": .string(message)]]
}

func forward(_ line: String) {
    guard let message = try? JSONValue.decode(line) else {
        writeLine(MCPServerCore.parseError())
        return
    }
    let id = message["id"]
    let isNotification = id == nil
    let body = Data(line.utf8)

    for attempt in 0..<2 {
        guard let endpoint = loadEndpoint() else {
            if attempt == 0 { launchAppIfNeeded(); continue }
            if !isNotification { writeLine(errorResponse(id: id, message: "ShowHow is not running. Open ShowHow and try again.")) }
            return
        }
        switch post(body, to: endpoint) {
        case .success(let (status, data)):
            if status == 202 || data.isEmpty { return }
            if let response = try? JSONValue.decode(data) {
                writeLine(response)
            } else if !isNotification {
                writeLine(errorResponse(id: id, message: "ShowHow returned HTTP \(status)."))
            }
            return
        case .failure(let error):
            if attempt == 0 { launchAppIfNeeded(); continue }
            if !isNotification { writeLine(errorResponse(id: id, message: "Could not reach ShowHow: \(error.localizedDescription)")) }
            return
        }
    }
}

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { continue }
    forward(trimmed)
}
