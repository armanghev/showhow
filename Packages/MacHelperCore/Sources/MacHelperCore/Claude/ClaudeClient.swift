import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An HTTP response whose body arrives as lines.
public struct LineResponse {
    public var status: Int
    public var headers: [String: String]
    public var lines: AsyncThrowingStream<String, Error>

    public init(status: Int, headers: [String: String], lines: AsyncThrowingStream<String, Error>) {
        self.status = status
        self.headers = headers
        self.lines = lines
    }
}

/// Moves bytes. The app uses `URLSessionLineTransport`; tests use a fake.
public protocol LineTransport: Sendable {
    func send(_ request: URLRequest) async throws -> LineResponse
}

public enum ClaudeError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case http(status: Int, type: String, message: String)
    case requestTooLarge(bytes: Int)
    case stream(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add your Anthropic API key in Settings > General."
        case .http(let status, let type, let message):
            return "The Claude API returned \(status) (\(type)): \(message)"
        case .requestTooLarge(let bytes):
            let mb = Double(bytes) / 1_048_576
            return String(format: "This walkthrough has grown too long to send (%.0f MB). Start a new one to continue.", mb)
        case .stream(let message):
            return message
        }
    }

    /// 429, 500-class and 529 (overloaded) are worth retrying.
    public var isRetryable: Bool {
        if case .http(let status, _, _) = self { return status == 429 || status == 408 || status >= 500 }
        return false
    }

    /// A 400 that names one of the optional beta features, so the caller can
    /// retry with that feature switched off instead of failing the session.
    public var rejectedFeature: OptionalFeature? {
        guard case .http(400, _, let message) = self else { return nil }
        let lower = message.lowercased()
        if lower.contains("compact") { return .compaction }
        if lower.contains("context_management") || lower.contains("clear_tool_uses") { return .contextEditing }
        return nil
    }

    public enum OptionalFeature: Equatable { case compaction, contextEditing }
}

/// Sends Messages API requests and rebuilds the streamed response.
public final class ClaudeClient: @unchecked Sendable {
    private let transport: LineTransport
    public var maxRetries = 3
    /// The API rejects bodies over 32 MB; stay safely under it.
    public var maxRequestBytes = 30 * 1_048_576
    private let sleeper: @Sendable (UInt64) async throws -> Void

    public init(transport: LineTransport, sleeper: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.transport = transport
        self.sleeper = sleeper
    }

    public func send(_ request: MessagesRequest, observer: StreamObserver? = nil) async throws -> AssistantMessage {
        let urlRequest = try request.urlRequest()
        let size = urlRequest.httpBody?.count ?? 0
        if size > maxRequestBytes { throw ClaudeError.requestTooLarge(bytes: size) }

        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await sendOnce(urlRequest, observer: observer)
            } catch let error as ClaudeError where error.isRetryable && attempt < maxRetries {
                attempt += 1
                let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                try await sleeper(delay)
            } catch StreamError.api(let type, let message) where type == "overloaded_error" && attempt < maxRetries {
                _ = message
                attempt += 1
                try await sleeper(UInt64(pow(2.0, Double(attempt))) * 1_000_000_000)
            }
        }
    }

    private func sendOnce(_ urlRequest: URLRequest, observer: StreamObserver?) async throws -> AssistantMessage {
        let response = try await transport.send(urlRequest)

        guard response.status == 200 else {
            var body = ""
            for try await line in response.lines { body += line + "\n" }
            let json = try? JSONValue.decode(body)
            throw ClaudeError.http(
                status: response.status,
                type: json?["error"]?["type"]?.stringValue ?? "http_error",
                message: json?["error"]?["message"]?.stringValue ?? body.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        var parser = SSEParser()
        let accumulator = StreamAccumulator(observer: observer)
        for try await line in response.lines {
            try Task.checkCancellation()
            for event in parser.feed(line: line) { try accumulator.handle(event) }
        }
        for event in parser.finish() { try accumulator.handle(event) }
        return try accumulator.finalMessage()
    }
}

#if canImport(Darwin)
/// URLSession transport that splits the body into lines itself, keeping blank
/// lines (Foundation's `lines` sequence drops them).
public struct URLSessionLineTransport: LineTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> LineResponse {
        let (bytes, response) = try await session.bytes(for: request)
        let http = response as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    var buffer = [UInt8]()
                    buffer.reserveCapacity(4096)
                    for try await byte in bytes {
                        if byte == 0x0A {
                            continuation.yield(String(decoding: buffer, as: UTF8.self))
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return LineResponse(status: http?.statusCode ?? 0, headers: headers, lines: stream)
    }
}
#endif
