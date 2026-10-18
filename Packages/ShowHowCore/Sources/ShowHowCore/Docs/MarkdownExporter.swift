import Foundation

/// The content of a write-up, built deterministically from the session log and
/// optionally polished by one text-only Claude call.
public struct WriteupDocument: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public var index: Int
        public var instruction: String
        public var tip: String?
        public var check: String?
        /// Image file name relative to the write-up folder, e.g. `images/step-01.jpg`.
        public var image: String?
        /// Seconds into the recording when the step started.
        public var recordingOffset: TimeInterval?

        public init(index: Int, instruction: String, tip: String? = nil, check: String? = nil, image: String? = nil, recordingOffset: TimeInterval? = nil) {
            self.index = index
            self.instruction = instruction
            self.tip = tip
            self.check = check
            self.image = image
            self.recordingOffset = recordingOffset
        }
    }

    public var title: String
    public var summary: String
    public var prerequisites: [String]
    public var steps: [Step]
    public var recording: String?
    public var date: Date

    public init(title: String, summary: String, prerequisites: [String], steps: [Step], recording: String? = nil, date: Date) {
        self.title = title
        self.summary = summary
        self.prerequisites = prerequisites
        self.steps = steps
        self.recording = recording
        self.date = date
    }
}

/// Polished text returned by the write-up call.
public struct WriteupPolish: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public var index: Int
        public var instruction: String
        public var tip: String
        public var check: String
    }

    public var title: String
    public var summary: String
    public var prerequisites: [String]
    public var steps: [Step]
}

public enum MarkdownExporter {
    /// Builds the document straight from the log, with no model call.
    public static func skeleton(from log: SessionLog) -> WriteupDocument {
        let completed = log.steps.filter { !$0.instruction.isEmpty || !$0.annotations.isEmpty }
        let steps = completed.enumerated().map { offset, step -> WriteupDocument.Step in
            let instruction = !step.instruction.isEmpty ? step.instruction
                : step.annotations.first?.label ?? step.expectedAction
            var check: String?
            if let action = step.userAction, step.verificationScreenshotFile != nil {
                check = "After you \(action.replacingOccurrences(of: "pressed Next", with: "finish")), the screen should match the next step."
            }
            let offsetSeconds = log.recordingStartedAt.map { step.startedAt.timeIntervalSince($0) }
            return WriteupDocument.Step(
                index: offset + 1,
                instruction: instruction,
                tip: step.detail.isEmpty ? nil : step.detail,
                check: check,
                image: step.screenshotFile == nil ? nil : imageName(for: offset + 1),
                recordingOffset: offsetSeconds.map { max(0, $0) }
            )
        }
        return WriteupDocument(
            title: log.title,
            summary: log.outcome.map { String($0.prefix(400)) } ?? "A step-by-step walkthrough recorded by ShowHow.",
            prerequisites: [],
            steps: steps,
            recording: log.recordingFile == nil ? nil : "recording.mov",
            date: log.startedAt
        )
    }

    public static func imageName(for index: Int) -> String {
        String(format: "images/step-%02d.jpg", index)
    }

    /// Applies the polished text, keeping images and offsets from the skeleton.
    public static func apply(_ polish: WriteupPolish, to doc: WriteupDocument) -> WriteupDocument {
        var out = doc
        if !polish.title.isEmpty { out.title = polish.title }
        if !polish.summary.isEmpty { out.summary = polish.summary }
        out.prerequisites = polish.prerequisites.filter { !$0.isEmpty }
        for p in polish.steps {
            guard let i = out.steps.firstIndex(where: { $0.index == p.index }) else { continue }
            if !p.instruction.isEmpty { out.steps[i].instruction = p.instruction }
            out.steps[i].tip = p.tip.isEmpty ? nil : p.tip
            out.steps[i].check = p.check.isEmpty ? out.steps[i].check : p.check
        }
        return out
    }

    public static func render(_ doc: WriteupDocument) -> String {
        var md = "# \(doc.title)\n\n"
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .none
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        md += "_\(dateFormatter.string(from: doc.date)) · \(doc.steps.count) step\(doc.steps.count == 1 ? "" : "s") · made with ShowHow_\n\n"
        md += doc.summary.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        if !doc.prerequisites.isEmpty {
            md += "## Before you start\n\n"
            for item in doc.prerequisites { md += "- \(item)\n" }
            md += "\n"
        }
        if let recording = doc.recording {
            md += "A screen recording of the whole walkthrough is in [\(recording)](\(recording)).\n\n"
        }
        for step in doc.steps {
            md += "## Step \(step.index)\n\n"
            if let image = step.image {
                md += "![Step \(step.index)](\(image))\n\n"
            }
            md += step.instruction.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            if let tip = step.tip, !tip.isEmpty { md += "> **Tip:** \(tip)\n\n" }
            if let check = step.check, !check.isEmpty { md += "**What to check:** \(check)\n\n" }
            if doc.recording != nil, let offset = step.recordingOffset {
                md += "_Recording: \(timestamp(offset))_\n\n"
            }
        }
        return md
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// `2026-10-18 Pivot table in Numbers` style folder names, safe for the file system.
    public static func folderName(for doc: WriteupDocument) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleanTitle = doc.title.components(separatedBy: illegal).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(f.string(from: doc.date)) \(String(cleanTitle.prefix(60)))"
    }

    // MARK: Polishing call

    public static let polishSchema: JSONValue = [
        "type": "object",
        "properties": [
            "title": ["type": "string"],
            "summary": ["type": "string"],
            "prerequisites": ["type": "array", "items": ["type": "string"]],
            "steps": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "index": ["type": "integer"],
                        "instruction": ["type": "string"],
                        "tip": ["type": "string"],
                        "check": ["type": "string"],
                    ],
                    "required": ["index", "instruction", "tip", "check"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["title", "summary", "prerequisites", "steps"],
        "additionalProperties": false,
    ]

    public static let polishSystem = """
    You turn the log of a guided software walkthrough into clear documentation that someone can follow later \
    without help. Write in plain, friendly language. Keep each instruction to one or two sentences that name \
    controls exactly as they appear on screen. Add a tip only when it explains why or warns about a common \
    mistake; otherwise leave it empty. The check says what the reader should see after the step. The summary is \
    two sentences. Prerequisites are short items such as the app and any file needed; leave the list empty if \
    there are none. Keep the same step indices and count.
    """

    public static func polishPrompt(for log: SessionLog, skeleton: WriteupDocument) -> String {
        var lines = ["Task: \(log.task)"]
        if let context = log.context, !context.isEmpty { lines.append("Context: \(context)") }
        if let outcome = log.outcome, !outcome.isEmpty { lines.append("Final recap from the guide: \(outcome)") }
        lines.append("")
        lines.append("Steps:")
        for (i, step) in skeleton.steps.enumerated() {
            let source = log.steps.filter { !$0.instruction.isEmpty || !$0.annotations.isEmpty }
            let raw = i < source.count ? source[i] : nil
            var line = "\(step.index). \(step.instruction)"
            if let raw {
                if !raw.detail.isEmpty { line += " | detail: \(raw.detail)" }
                if !raw.elementNames.isEmpty { line += " | controls: \(raw.elementNames.joined(separator: ", "))" }
                if let action = raw.userAction { line += " | user then: \(action)" }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}
