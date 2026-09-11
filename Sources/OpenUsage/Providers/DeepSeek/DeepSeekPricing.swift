import Foundation

/// DeepSeek's own per-token rates, which are **peak/off-peak** and therefore cannot live in the shared
/// `pricing_supplement.json`: that schema carries one rate set per model, and these rates change with the
/// wall-clock hour the request was made. So the DeepSeek card prices its DSH traffic here instead, from a
/// table transcribed from DeepSeek's published rates.
///
/// Source: <https://api-docs.deepseek.com/quick_start/pricing> (USD per 1M tokens). The peak window is
/// UTC Monday–Friday 01:00–04:00 and 06:00–10:00; **every other hour is off-peak, at exactly half the peak
/// rate**, which is why the table stores only the peak row and derives the rest.
///
/// Re-check this table whenever DeepSeek re-prices: it is the one place in the app where a rate cannot
/// arrive through the shared pricing feeds.
enum DeepSeekPricing {
    struct Rates: Equatable, Sendable {
        /// Prompt tokens that missed the cache.
        var inputPerMillion: Double
        /// Prompt tokens that hit the cache.
        var cacheReadPerMillion: Double
        /// Completion tokens (reasoning tokens are a subset and must not be billed twice).
        var outputPerMillion: Double
    }

    /// Peak rates per model, keyed by the model ids DSH reports.
    ///
    /// `deepseek-v4-flash` and `deepseek-v4-flash-vision-exp` are retired names that DeepSeek still
    /// accepts and serves with V4.1 Flash at the Flash price, so they map to the same row. From
    /// 2026-09-14 `deepseek-v4-pro` requests are likewise routed to and billed as Flash.
    static let peakRates: [String: Rates] = [
        "deepseek-flash": Rates(inputPerMillion: 0.30, cacheReadPerMillion: 0.006, outputPerMillion: 1.20),
        "deepseek-v4-flash": Rates(inputPerMillion: 0.30, cacheReadPerMillion: 0.006, outputPerMillion: 1.20),
        "deepseek-v4-flash-vision-exp": Rates(inputPerMillion: 0.30, cacheReadPerMillion: 0.006, outputPerMillion: 1.20),
        "deepseek-v4-pro": Rates(inputPerMillion: 1.32, cacheReadPerMillion: 0.044, outputPerMillion: 3.96)
    ]

    /// Peak and off-peak rates for a model, or `nil` for a model this table doesn't know — the caller
    /// then leaves the request unpriced rather than inventing a rate.
    static func rates(for model: String) -> (peak: Rates, offPeak: Rates)? {
        guard let peak = peakRates[model] else { return nil }
        return (peak, Rates(
            inputPerMillion: peak.inputPerMillion / 2,
            cacheReadPerMillion: peak.cacheReadPerMillion / 2,
            outputPerMillion: peak.outputPerMillion / 2
        ))
    }

    /// Whether `date` falls in DeepSeek's peak window: UTC Monday–Friday, 01:00–04:00 or 06:00–10:00.
    /// Off-peak is everything else and bills at half.
    static func isPeak(_ date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        // `weekday` is 1 = Sunday … 7 = Saturday; the peak window is Monday–Friday.
        guard let weekday = parts.weekday, (2...6).contains(weekday), let hour = parts.hour else {
            return false
        }
        return (1..<4).contains(hour) || (6..<10).contains(hour)
    }

    /// The cost of one request's tokens at the rate tier its timestamp falls in, or `nil` when the model
    /// has no known rate.
    static func cost(for model: String, tokens: TokenBreakdown, at date: Date) -> Double? {
        guard let table = rates(for: model) else { return nil }
        let rate = isPeak(date) ? table.peak : table.offPeak
        return (Double(tokens.input) * rate.inputPerMillion
            + Double(tokens.cacheRead) * rate.cacheReadPerMillion
            + Double(tokens.cacheWrite5m + tokens.cacheWrite1h) * rate.inputPerMillion
            + Double(tokens.output) * rate.outputPerMillion) / 1_000_000
    }
}
