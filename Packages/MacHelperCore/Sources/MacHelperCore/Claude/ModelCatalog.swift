import Foundation

/// The models the app offers, with the request features each one accepts and
/// its list prices (USD per million tokens) for the cost meter.
public enum ClaudeModel: String, CaseIterable, Codable, Sendable, Identifiable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .opus: return "Claude Opus 5.5"
        case .sonnet: return "Claude Sonnet 5.5"
        case .haiku: return "Claude Haiku 5.5"
        }
    }

    public var blurb: String {
        switch self {
        case .opus: return "Best guidance on messy screens"
        case .sonnet: return "About half the price, great for everyday use"
        case .haiku: return "Cheapest, good for quick \"where is X\" lookups"
        }
    }

    /// Server-side refusal fallback (`fallbacks: "default"`) is offered on the
    /// Claude API for Opus 5.5 and Sonnet 5.5, not for Haiku 5.5.
    public var supportsDefaultFallbacks: Bool { self != .haiku }

    /// `thinking.display: "updates"` (progress notes between tool calls).
    /// Haiku gets `"summarized"` instead.
    public var thinkingDisplay: String { self == .haiku ? "summarized" : "updates" }

    public var pricing: ModelPricing {
        switch self {
        case .opus: return ModelPricing(input: 4.00, output: 20.00, cacheWrite: 5.00, cacheRead: 0.20)
        case .sonnet: return ModelPricing(input: 2.00, output: 10.00, cacheWrite: 2.50, cacheRead: 0.20)
        case .haiku: return ModelPricing(input: 0.10, output: 0.50, cacheWrite: 0.125, cacheRead: 0.01)
        }
    }
}

public enum Effort: String, CaseIterable, Codable, Sendable, Identifiable {
    case low, medium, high, xhigh, max
    public var id: String { rawValue }
}

public struct ModelPricing: Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheWrite: Double
    public var cacheRead: Double

    /// Approximate cost of a request in USD. Cache-write pricing is the
    /// five-minute rate; treat the result as an estimate, as the plan says.
    public func cost(of usage: Usage) -> Double {
        let perToken = 1.0 / 1_000_000
        return Double(usage.inputTokens) * input * perToken
            + Double(usage.outputTokens) * output * perToken
            + Double(usage.cacheCreationInputTokens) * cacheWrite * perToken
            + Double(usage.cacheReadInputTokens) * cacheRead * perToken
    }
}

/// Running total for the menu bar footer and the session log.
public struct CostMeter: Codable, Equatable, Sendable {
    public private(set) var usage = Usage()
    public private(set) var dollars: Double = 0
    public private(set) var requests = 0

    public init() {}

    public mutating func add(_ usage: Usage, model: ClaudeModel) {
        self.usage = self.usage + usage
        dollars += model.pricing.cost(of: usage)
        requests += 1
    }

    public var formatted: String {
        if dollars < 0.01 { return dollars == 0 ? "$0.00" : "<$0.01" }
        return String(format: "$%.2f", dollars)
    }
}
