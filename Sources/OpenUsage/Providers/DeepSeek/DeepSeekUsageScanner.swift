import Foundation

/// Reads the token usage DSH (DeepSeek Harness) records for the DeepSeek card's spend tiles and usage
/// trend.
///
/// DeepSeek publishes no usage endpoint — its OpenAPI is chat/models/balance and nothing else — so the
/// only *measured* numbers for this machine come from a client that talks to the API. DSH writes one
/// append-only event log per session at
/// `~/.dsh/sessions/<escaped-cwd>/session-<uuid>/session.v3.jsonl.zstd`, and every model request it makes
/// lands as its own `assistant/message` record carrying the provider's own usage:
///
///     { "type": "assistant/message", "time": <epoch ms>,
///       "data": { "message": { "id": …, "source": { "provider": …, "model": … } },
///                 "usage": { "inputTokens", "cacheReadTokens", "cacheWriteTokens", "outputTokens" } } }
///
/// Verified against a session's compressed log: for every request, `inputTokens + cacheReadTokens +
/// outputTokens == totalTokens`, and `reasoningTokens` is a subset of the output — so the buckets are
/// disjoint and `inputTokens` is the **uncached** prompt. That maps straight onto `TokenBreakdown`.
///
/// Because each request keeps its own timestamp, usage is attributed to the local day it actually
/// happened (not to the session's start) and priced at `DeepSeekPricing`'s peak or off-peak tier for that
/// instant — DeepSeek's rates halve outside the peak window, so a session-level total could not be priced
/// without guessing.
///
/// A `Sendable` struct, `async` and nonisolated, so the file reads run off the main actor when the
/// `@MainActor` provider `await`s it.
struct DeepSeekUsageScanner: Sendable {
    /// The model reported for a request whose record carried no model id.
    static let unknownModel = "Unknown DeepSeek Model"
    /// How many distinct archive paths may be reported as failing before the scan is treated as broken
    /// rather than partially readable. Bounds the log noise from a wholesale permissions problem.
    static let maximumReportedFailures = 8

    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL
    var sessionLogFiles: @Sendable (String) -> [String]
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        sessionLogFiles: @escaping @Sendable (String) -> [String] = DeepSeekPaths.sessionLogFiles(home:),
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.sessionLogFiles = sessionLogFiles
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("deepseek"),
            warning: readFailureWarning
        )
    }

    /// One model request's measured usage.
    struct Entry: Sendable, Equatable {
        var messageID: String
        var timestamp: Date
        var model: String
        var tokens: TokenBreakdown
    }

    private struct ParseState: Sendable {
        /// Requests are keyed by message id so a resumed or forked session that replays a transcript
        /// cannot count the same request twice.
        var seenMessageIDs: Set<String> = []
        var entries: [Entry] = []
    }

    /// Scan the last `daysBack` days. Returns `nil` when DSH has no session logs at all — DSH was never
    /// used here. A present-but-idle set yields an empty scan (the tiles read "No data").
    func scan(daysBack: Int = 30, now: Date = Date()) async throws -> LogUsageScan? {
        let home = DeepSeekPaths.homeDirectory(environment: environment, homeDirectory: homeDirectory())
        let paths = sessionLogFiles(home)
        guard !paths.isEmpty else {
            await readFailureReporter.update(checkedPaths: [], failingPaths: [])
            return nil
        }

        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        var state = ParseState()
        var checked: Set<String> = []
        var failures: [String: String] = [:]

        for path in paths {
            checked.insert(path)
            // A log untouched since before the window cannot hold an in-window request: DSH appends in
            // time order, so the file's own mtime bounds its newest record. This is what keeps the
            // decompression cost proportional to recent activity rather than to the whole history.
            guard Self.isWithinWindow(path: path, since: since) else { continue }
            do {
                try Self.appendEntries(from: path, state: &state)
            } catch {
                failures[path] = error.localizedDescription
            }
        }

        // Per-path detail is logged only for newly failing paths (the reporter edge-triggers), so a
        // persistently unreadable log warns once instead of on every refresh.
        let newlyFailing = await readFailureReporter.update(checkedPaths: checked, failingPaths: Set(failures.keys))
        for path in newlyFailing.sorted().prefix(Self.maximumReportedFailures) {
            AppLog.warn(LogTag.plugin("deepseek"), "session log read failed for \(path): \(failures[path] ?? "unknown error")")
        }
        if !failures.isEmpty, failures.count == checked.count {
            throw DeepSeekUsageError.logsUnreadable
        }
        return Self.aggregate(entries: state.entries, since: since)
    }

    /// Cheap local probe for `hasLocalCredentials()`: does any session log hold at least one request with
    /// usage? Read-only, no network, and it stops at the first hit rather than reading a whole history.
    func hasSessionUsage() -> Bool {
        let home = DeepSeekPaths.homeDirectory(environment: environment, homeDirectory: homeDirectory())
        let marker = Data(#""usage""#.utf8)
        for path in sessionLogFiles(home) {
            var found = false
            // A failure here is not fatal to the probe: an unreadable log still means DSH ran here, which
            // is all this answer needs.
            _ = try? ZstdLineReader.forEachLine(at: path) { line in
                if line.count > 0, Data(line).range(of: marker) != nil {
                    found = true
                    return false
                }
                return true
            }
            if found { return true }
        }
        return false
    }

    // MARK: - Reading

    /// Whether `path` was modified inside the scan window. A stat failure counts as in-window so a file
    /// we can't inspect still gets a read attempt (and therefore a reported failure).
    private static func isWithinWindow(path: String, since: Date) -> Bool {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let mtime = values.contentModificationDate
        else { return true }
        return mtime >= since
    }

    /// Stream one session log and append its requests to `state`.
    private static func appendEntries(from path: String, state: inout ParseState) throws {
        let marker = Data(#""assistant/message""#.utf8)
        try ZstdLineReader.forEachLine(at: path) { line in
            // Cheap reject before the JSON parse: most records in a transcript are tool calls, results,
            // and reasoning deltas, and only the completed assistant messages carry usage.
            guard Data(line).range(of: marker) != nil else { return true }
            guard let entry = Self.parse(line), state.seenMessageIDs.insert(entry.messageID).inserted else {
                return true
            }
            state.entries.append(entry)
            return true
        }
    }

    /// Parse one event-log line into a usage entry, or `nil` for anything else.
    static func parse(_ line: UnsafeRawBufferPointer) -> Entry? {
        guard line.count > 0,
              let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              object["type"] as? String == "assistant/message",
              let timestampMs = ProviderParse.number(object["time"]),
              timestampMs > 0,
              let data = object["data"] as? [String: Any],
              let usage = data["usage"] as? [String: Any]
        else { return nil }

        let tokens = tokenBreakdown(usage)
        // A request that moved no tokens tells us nothing about spend, and counting it would add an
        // empty day.
        guard tokens.totalTokens > 0 else { return nil }

        let message = data["message"] as? [String: Any]
        // Fall back to the record's sequence number for a message with no id, so two records still can't
        // collapse into one entry.
        let sequence = ProviderParse.number(object["seq"]).map { String(Int($0)) } ?? "?"
        return Entry(
            messageID: messageID(in: message) ?? "seq:\(sequence)",
            timestamp: Date(timeIntervalSince1970: timestampMs / 1000),
            model: modelName(in: message),
            tokens: tokens
        )
    }

    private static func messageID(in message: [String: Any]?) -> String? {
        (message?["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Which model served the request, from the message's own source block.
    private static func modelName(in message: [String: Any]?) -> String {
        guard let source = message?["source"] as? [String: Any],
              let model = (source["model"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else { return unknownModel }
        return model
    }

    /// DeepSeek reports four disjoint buckets. `inputTokens` is the **uncached** prompt (it does not
    /// include cache reads — verified: input + cacheRead + output == total for every request), so it maps
    /// to `TokenBreakdown.input` directly. Cache writes are billed at the input rate in `DeepSeekPricing`.
    static func tokenBreakdown(_ usage: [String: Any]) -> TokenBreakdown {
        TokenBreakdown(
            input: boundedTokenCount(usage["inputTokens"]),
            cacheWrite5m: boundedTokenCount(usage["cacheWriteTokens"]),
            cacheRead: boundedTokenCount(usage["cacheReadTokens"]),
            output: boundedTokenCount(usage["outputTokens"])
        )
    }

    /// `Int(Double)` traps above `Int.max`; 1e15 is far above any real per-request token count.
    private static func boundedTokenCount(_ value: Any?) -> Int {
        Int(min(max(ProviderParse.number(value) ?? 0, 0), 1e15))
    }

    // MARK: - Aggregation

    /// Sum the requests into the daily series behind the spend tiles and the trend, pricing each one at
    /// the peak or off-peak tier of the instant it was made. A request whose model the rate table doesn't
    /// know is left unpriced and flagged, so the tile warns instead of showing a confident zero.
    static func aggregate(entries: [Entry], since: Date) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()

        for entry in entries {
            guard entry.timestamp >= since else { continue }
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            guard let cost = DeepSeekPricing.cost(for: entry.model, tokens: entry.tokens, at: entry.timestamp) else {
                accumulator.addUnknownModel(day: day, model: entry.model)
                continue
            }
            accumulator.add(day: day, tokens: entry.tokens.totalTokens, cost: cost, model: entry.model)
        }
        return accumulator.build()
    }
}
