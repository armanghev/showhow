import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// One guided step as it happened.
public struct LogStep: Codable, Equatable, Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var startedAt: Date
    /// File name (inside the session folder) of the screenshot Claude saw when it gave the step.
    public var screenshotFile: String?
    public var screenshotMapping: ScreenshotMapping?
    public var annotations: [Annotation]
    public var instruction: String
    public var detail: String
    public var expectedAction: String
    public var elementNames: [String]
    public var userAction: String?
    public var verificationScreenshotFile: String?
    public var completedAt: Date?
    /// Password fields visible in the screenshot, in display-local points; blurred on export.
    public var secureRects: [CGRect]

    public init(index: Int, startedAt: Date, screenshotFile: String? = nil, screenshotMapping: ScreenshotMapping? = nil,
                annotations: [Annotation] = [], instruction: String = "", detail: String = "", expectedAction: String = "",
                elementNames: [String] = [], userAction: String? = nil, verificationScreenshotFile: String? = nil,
                completedAt: Date? = nil, secureRects: [CGRect] = [])
    {
        self.index = index
        self.startedAt = startedAt
        self.screenshotFile = screenshotFile
        self.screenshotMapping = screenshotMapping
        self.annotations = annotations
        self.instruction = instruction
        self.detail = detail
        self.expectedAction = expectedAction
        self.elementNames = elementNames
        self.userAction = userAction
        self.verificationScreenshotFile = verificationScreenshotFile
        self.completedAt = completedAt
        self.secureRects = secureRects
    }
}

public struct LogEntry: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case user, assistant, note, action, system }
    public var date: Date
    public var kind: Kind
    public var text: String

    public init(date: Date = Date(), kind: Kind, text: String) {
        self.date = date
        self.kind = kind
        self.text = text
    }
}

/// Everything recorded about a session: the basis for review and write-ups.
public struct SessionLog: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var task: String
    public var context: String?
    public var sourceLabel: String
    public var mode: AgentMode
    public var model: String
    public var startedAt: Date
    public var endedAt: Date?
    public var steps: [LogStep]
    public var entries: [LogEntry]
    public var documentRequested: Bool
    public var recordRequested: Bool
    public var recordingFile: String?
    public var recordingStartedAt: Date?
    public var cost: CostMeter
    public var outcome: String?
    /// Absolute path of the exported write-up folder, once made. Documented
    /// sessions are kept past the retention window.
    public var writeupPath: String?

    public init(id: UUID = UUID(), task: String, context: String? = nil, sourceLabel: String, mode: AgentMode, model: String, startedAt: Date = Date()) {
        self.id = id
        self.task = task
        self.context = context
        self.sourceLabel = sourceLabel
        self.mode = mode
        self.model = model
        self.startedAt = startedAt
        self.steps = []
        self.entries = []
        self.documentRequested = false
        self.recordRequested = false
        self.cost = CostMeter()
    }

    public var title: String {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? trimmed
        return firstLine.count > 60 ? String(firstLine.prefix(57)) + "..." : firstLine
    }
}

/// Reads and writes session folders:
/// `<root>/<session id>/log.json` plus `images/*.jpg` and an optional recording.
public final class SessionLogStore: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default
    private let lock = NSLock()

    public init(root: URL) {
        self.root = root
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func imageURL(session id: UUID, file: String) -> URL {
        folder(for: id).appendingPathComponent("images", isDirectory: true).appendingPathComponent(file)
    }

    public func save(_ log: SessionLog) throws {
        lock.lock(); defer { lock.unlock() }
        let dir = folder(for: log.id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(log).write(to: dir.appendingPathComponent("log.json"), options: .atomic)
    }

    /// Saves an image and returns its file name.
    @discardableResult
    public func saveImage(_ data: Data, session id: UUID, name: String) throws -> String {
        let dir = folder(for: id).appendingPathComponent("images", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        return name
    }

    public func load(_ id: UUID) throws -> SessionLog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionLog.self, from: Data(contentsOf: folder(for: id).appendingPathComponent("log.json")))
    }

    /// Most recent first.
    public func recent(limit: Int = 10) -> [SessionLog] {
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        let logs = dirs.compactMap { UUID(uuidString: $0.lastPathComponent) }.compactMap { try? load($0) }
        return Array(logs.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    /// Deletes sessions older than `days` that were never turned into a write-up.
    @discardableResult
    public func purge(olderThan days: Int, now: Date = Date()) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var removed = 0
        for log in recent(limit: .max) where log.startedAt < cutoff && log.writeupPath == nil {
            if (try? fm.removeItem(at: folder(for: log.id))) != nil { removed += 1 }
        }
        return removed
    }

    /// Deletes every session log except those that became write-ups.
    @discardableResult
    public func deleteAll() -> Int {
        var removed = 0
        for log in recent(limit: .max) where log.writeupPath == nil {
            if (try? fm.removeItem(at: folder(for: log.id))) != nil { removed += 1 }
        }
        return removed
    }
}

/// Keeps the log for the running session up to date and persisted.
public final class SessionRecorder: @unchecked Sendable {
    public private(set) var log: SessionLog
    public let store: SessionLogStore
    private var imageCounter = 0
    private let lock = NSLock()

    public init(log: SessionLog, store: SessionLogStore) {
        self.log = log
        self.store = store
        persist()
    }

    public func update(_ change: (inout SessionLog) -> Void) {
        lock.lock()
        change(&log)
        lock.unlock()
        persist()
    }

    public func note(_ kind: LogEntry.Kind, _ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        update { $0.entries.append(LogEntry(kind: kind, text: text)) }
    }

    /// Stores a screenshot and returns its file name.
    public func saveScreenshot(_ shot: Screenshot) -> String? {
        lock.lock()
        imageCounter += 1
        let name = String(format: "shot-%03d.%@", imageCounter, shot.mediaType == "image/png" ? "png" : "jpg")
        lock.unlock()
        return try? store.saveImage(shot.data, session: log.id, name: name)
    }

    public var currentStep: LogStep? { log.steps.last(where: { $0.completedAt == nil }) }

    /// Opens a step, or updates the open one.
    public func recordStepContent(screenshotFile: String?, mapping: ScreenshotMapping?, annotations: [Annotation]? = nil,
                                  instruction: String? = nil, detail: String? = nil, expected: String? = nil,
                                  elementNames: [String] = [], secureRects: [CGRect] = [])
    {
        update { log in
            if log.steps.last?.completedAt != nil || log.steps.isEmpty {
                log.steps.append(LogStep(index: log.steps.count + 1, startedAt: Date(), screenshotFile: screenshotFile,
                                         screenshotMapping: mapping, secureRects: secureRects))
            }
            var step = log.steps.removeLast()
            if step.screenshotFile == nil {
                step.screenshotFile = screenshotFile
                step.screenshotMapping = mapping
                step.secureRects = secureRects
            }
            if let annotations { step.annotations += annotations }
            if let instruction, !instruction.isEmpty { step.instruction = instruction }
            if let detail, !detail.isEmpty { step.detail = detail }
            if let expected, !expected.isEmpty { step.expectedAction = expected }
            for name in elementNames where !step.elementNames.contains(name) { step.elementNames.append(name) }
            log.steps.append(step)
        }
    }

    public func completeStep(userAction: String, verificationFile: String?) {
        update { log in
            guard var step = log.steps.last, step.completedAt == nil else { return }
            log.steps.removeLast()
            step.userAction = userAction
            step.verificationScreenshotFile = verificationFile
            step.completedAt = Date()
            log.steps.append(step)
        }
    }

    public func persist() {
        try? store.save(log)
    }
}
