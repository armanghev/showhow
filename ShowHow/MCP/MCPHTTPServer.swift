import Foundation
import ShowHowCore
import Network

/// Serves MCP over Streamable HTTP (JSON responses) on 127.0.0.1 only, with a
/// per-install bearer token. Claude Code connects directly; Claude Desktop goes
/// through the bundled `showhow-mcp` stdio bridge.
@MainActor
final class MCPHTTPServer {
    static let shared = MCPHTTPServer()

    private var listener: NWListener?
    private var router: MCPHTTPRouter?
    private let queue = DispatchQueue(label: "com.armanghev.ShowHow.mcp")
    private(set) var endpoint: MCPEndpointInfo?

    func start() {
        guard listener == nil else { return }
        let settings = AppSettings.shared
        settings.ensureMCPCredentials()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let core = MCPServerCore(serverVersion: version, delegate: SessionController.shared)
        let router = MCPHTTPRouter(core: core, token: settings.mcpToken)
        self.router = router

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(settings.mcpPort))!)
            let listener = try NWListener(using: parameters)
            let queue = self.queue
            listener.newConnectionHandler = { connection in
                Self.serve(connection, router: router, queue: queue)
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.handle(state) }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            AppModel.shared.attention = "The MCP server could not start: \(error.localizedDescription)"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        endpoint = nil
        try? FileManager.default.removeItem(at: MCPEndpointInfo.defaultURL())
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            let settings = AppSettings.shared
            let info = MCPEndpointInfo(port: settings.mcpPort, token: settings.mcpToken)
            endpoint = info
            IntegrationInstaller.writeEndpointFile(info)
        case .failed(let error):
            listener?.cancel()
            listener = nil
            if case .posix(let code) = error, code == .EADDRINUSE {
                // Pick another port next time and try once more.
                AppSettings.shared.mcpPort = 0
                start()
            } else {
                AppModel.shared.attention = "The MCP server stopped: \(error.localizedDescription)"
            }
        default:
            break
        }
    }

    /// Reads one request at a time from a connection and answers it.
    private nonisolated static func serve(_ connection: NWConnection, router: MCPHTTPRouter, queue: DispatchQueue) {
        // Only loopback peers are accepted.
        if case .hostPort(let host, _) = connection.endpoint {
            switch host {
            case .ipv4(let address) where address == .loopback: break
            case .ipv6(let address) where address == .loopback: break
            case .name(let name, _) where name == "localhost": break
            default:
                connection.cancel()
                return
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data(), router: router)
    }

    private nonisolated static func receive(on connection: NWConnection, buffer: Data, router: MCPHTTPRouter) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil {
                connection.cancel()
                return
            }
            switch HTTPRequest.parse(buffer) {
            case .incomplete:
                if isComplete { connection.cancel() } else { receive(on: connection, buffer: buffer, router: router) }
            case .invalid(let reason):
                send(HTTPResponse.text(reason, status: 400), on: connection, keepAlive: false, router: router, rest: Data())
            case .complete(let request, let consumed):
                let rest = Data(buffer.dropFirst(consumed))
                Task {
                    let response = await router.route(request)
                    let keepAlive = request.header("connection")?.lowercased() != "close"
                    send(response, on: connection, keepAlive: keepAlive && !isComplete, router: router, rest: rest)
                }
            }
        }
    }

    private nonisolated static func send(_ response: HTTPResponse, on connection: NWConnection, keepAlive: Bool, router: MCPHTTPRouter, rest: Data) {
        var response = response
        response.headers["Connection"] = keepAlive ? "keep-alive" : "close"
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            if keepAlive {
                receive(on: connection, buffer: rest, router: router)
            } else {
                connection.cancel()
            }
        })
    }
}
