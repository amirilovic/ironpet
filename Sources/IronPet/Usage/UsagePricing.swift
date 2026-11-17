import Foundation

/// Token prices in USD per million tokens, for the one case where ironpet prices a turn itself: the first turn after a
/// resumed session, where the agent reports only the session's lifetime cost and the turn's own share is unknown.
/// A model that is not listed has no price, and its turn is recorded without a cost.
enum UsagePricing {
    struct Prices {
        var input = 0.0
        var output = 0.0
        var cacheRead = 0.0
        var cacheWrite = 0.0
    }

    /// Only components confirmed against recorded costs are filled in (cache read $0.20 and output $20 for Claude Opus 5.5).
    /// The others stay 0, so a priced turn is a little low by its input and cache write tokens, never high.
    static let table: [(prefix: String, prices: Prices)] = [
        ("claude-opus-5-5", Prices(input: 0, output: 20, cacheRead: 0.20, cacheWrite: 0)),
    ]

    static func prices(for model: String) -> Prices? {
        table.first { model.hasPrefix($0.prefix) }?.prices
    }

    /// Dollars for the turn's reported tokens, or nil when the model has no price or no priced token count was reported.
    static func cost(for event: UsageEvent) -> Double? {
        guard let prices = prices(for: event.model) else { return nil }
        let counts = [event.inputTokens, event.outputTokens, event.cacheReadTokens, event.cacheWriteTokens]
        guard counts.contains(where: { $0 != nil }) else { return nil }
        let sum = Double(event.inputTokens ?? 0) * prices.input + Double(event.outputTokens ?? 0) * prices.output
            + Double(event.cacheReadTokens ?? 0) * prices.cacheRead + Double(event.cacheWriteTokens ?? 0) * prices.cacheWrite
        // Only unpriced components were reported (an input-only turn, say). That is no price, not a free turn.
        return sum > 0 ? sum / 1_000_000 : nil
    }

    /// Dollars per million tokens that no input or cache write token costs more than. Prices for those two components are not
    /// known, so the migration leaves a row alone when its input and cache write tokens could account for the cost.
    static let generousUnpricedRate = 15.0

    /// SQL that sets a chat row's cost to its token-implied value when the recorded cost is over 20 times that value.
    /// One statement per priced model, so the rule and the table cannot drift apart.
    static var correctionSQL: String {
        table.map { entry in
            let p = entry.prices
            let implied = "((COALESCE(input_tokens, 0) * \(p.input) + COALESCE(output_tokens, 0) * \(p.output) + COALESCE(cache_read_tokens, 0) * \(p.cacheRead) + COALESCE(cache_write_tokens, 0) * \(p.cacheWrite)) / 1000000.0)"
            return "UPDATE usage_events SET cost = \(implied) WHERE feature = 'chat' AND model LIKE '\(entry.prefix)%' AND cost IS NOT NULL AND \(implied) > 0 AND cost > 20 * \(implied) AND cost > \(implied) + (COALESCE(input_tokens, 0) + COALESCE(cache_write_tokens, 0)) * \(Self.generousUnpricedRate) / 1000000.0;"
        }.joined(separator: "\n")
    }
}
