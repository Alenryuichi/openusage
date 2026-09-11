import Foundation

/// Reads WorkBuddy's local session transcripts (`~/.workbuddy/projects/<workspace>/<session>.jsonl`) for
/// the spend tiles and usage trend. Cookie-free and local-only.
///
/// WorkBuddy (Tencent's CodeBuddy-family agent) writes one append-only JSONL transcript per session, and
/// every model request it makes lands as its own record carrying the provider's **real** usage in
/// `providerData.rawUsage` — prompt, completion, and cache-hit token counts. One request is one record,
/// so the scan sums them rather than imputing anything.
///
/// Tokens are measured; the dollars are **estimated** (the ⓘ): WorkBuddy bills through its own plan, so
/// the token counts are priced at public API rates through the shared model pricing, exactly like
/// Claude/Codex/Grok/Zcode. Models no pricing source knows are excluded from the totals and surfaced as
/// a warning triangle instead of being silently priced at zero.
///
/// A `Sendable` struct (like the Zcode scanner), `async` and nonisolated, so the file reads run off the
/// main actor when the `@MainActor` provider `await`s it.
struct WorkBuddyUsageScanner: Sendable {
    /// The record key holding a request's authoritative usage. Used both as the parse filter and as the
    /// cheap first-run probe marker.
    static let usageKey = "rawUsage"
    /// How much of a transcript the presence probe reads before giving up on it. A session log records
    /// its first request within the first few records, so this is generous.
    static let probeByteCount = 256 * 1024
    /// Shown in the unknown-model warning for a record with no model id at all.
    static let unknownModel = "Unknown WorkBuddy Model"

    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL
    var logFiles: @Sendable (String) -> [String]
    private let readFailureReporter: UsageLogReadFailureReporter

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        logFiles: @escaping @Sendable (String) -> [String] = WorkBuddyPaths.logFiles(in:),
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.logFiles = logFiles
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("workbuddy"),
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

    /// A parsed batch: the requests one read chunk contained. Not private so the parser is directly
    /// testable without materializing a transcript on disk.
    struct Batch: Sendable {
        var entries: [Entry] = []
    }

    private struct ParseState: Sendable {
        /// Every message id already counted. Two records can describe the same request (a resumed or
        /// forked session replays the transcript), and the message id is unique per request — so the
        /// first spelling wins and the duplicate contributes nothing, not its tokens and not its day.
        var seenMessageIDs: Set<String> = []
        var entries: [Entry] = []
    }

    /// Scan the last `daysBack` days. Returns `nil` when there are no transcripts at all — WorkBuddy was
    /// never used here. A present-but-idle tree yields an empty scan (the tiles collapse to "No data").
    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async throws -> LogUsageScan? {
        let paths = logFiles(homeDirectoryPath())
        guard !paths.isEmpty else {
            await readFailureReporter.update(checkedPaths: [], failingPaths: [])
            return nil
        }

        // Same calendar bound the tiles and trend use, so a morning request on the oldest day is not lost
        // to a wall-clock cutoff that would sit later the same day.
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        var checked: Set<String> = []
        var failures: [String: String] = [:]
        var state = ParseState()

        for path in paths {
            checked.insert(path)
            // A transcript untouched since before the window cannot hold an in-window request: records
            // are appended in time order, so the file's own mtime bounds its newest one.
            guard Self.isWithinWindow(path: path, since: since) else { continue }
            do {
                try Self.appendEntries(from: path, state: &state)
            } catch {
                failures[path] = error.localizedDescription
            }
        }

        // Per-path detail is logged only for newly failing paths (the reporter edge-triggers), so a
        // persistently unreadable transcript warns once instead of on every refresh.
        let newlyFailing = await readFailureReporter.update(checkedPaths: checked, failingPaths: Set(failures.keys))
        for path in newlyFailing.sorted() {
            AppLog.warn(LogTag.plugin("workbuddy"), "transcript read failed for \(path): \(failures[path] ?? "unknown error")")
        }
        if !failures.isEmpty, failures.count == checked.count {
            throw WorkBuddyUsageError.logsUnreadable
        }
        return Self.aggregate(
            entries: state.entries,
            since: since,
            pricing: pricing
        )
    }

    /// Cheap local probe for `hasLocalCredentials()`: does any transcript hold at least one record with a
    /// usage block? Read-only, no network. This runs only during first-run / new-provider detection, so
    /// it reads a bounded prefix per file and stops at the first hit rather than parsing whole sessions.
    func hasModelUsage() -> Bool {
        let paths = logFiles(homeDirectoryPath())
        guard !paths.isEmpty else { return false }

        let marker = Data(Self.usageKey.utf8)
        for path in paths {
            guard let handle = FileHandle(forReadingAtPath: path) else {
                // A transcript that exists but can't be opened is itself a WorkBuddy footprint — enable
                // the provider so `refresh()` gets to surface the actionable error.
                AppLog.warn(LogTag.plugin("workbuddy"), "usage probe could not open \(path)")
                return true
            }
            defer { try? handle.close() }
            let prefix = (try? handle.read(upToCount: Self.probeByteCount)) ?? Data()
            if prefix.range(of: marker) != nil { return true }
        }
        return false
    }

    private func homeDirectoryPath() -> String {
        WorkBuddyPaths.homeDirectory(environment: environment, homeDirectory: homeDirectory())
    }

    // MARK: - File discovery helpers

    /// Whether `path` was modified inside the scan window. A stat failure counts as in-window so a file
    /// we can't inspect still gets a read attempt (and therefore a reported failure) instead of being
    /// silently skipped as if it were old.
    private static func isWithinWindow(path: String, since: Date) -> Bool {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let mtime = values.contentModificationDate
        else { return true }
        return mtime >= since
    }

    /// Stream one transcript and fold its requests into `state`. Throws when the file can't be read.
    private static func appendEntries(from path: String, state: inout ParseState) throws {
        let result = try JSONLStreamingReader.read(
            path: path,
            initialState: JSONLStatelessParserState()
        ) { data, _ in
            Self.parse(data)
        }
        // A nil item list means the read was cancelled; propagate rather than reporting a partial scan.
        guard let batches = result.items else { throw CancellationError() }

        for batch in batches {
            for entry in batch.entries where state.seenMessageIDs.insert(entry.messageID).inserted {
                state.entries.append(entry)
            }
        }
    }

    // MARK: - Parsing

    /// Parse a batch of complete JSONL records. A record without a usage block, without a message id, or
    /// with a non-positive timestamp is skipped at this boundary; a record that moved no tokens (an
    /// errored or fully-cached call the provider still logged) is skipped too, because counting it would
    /// add an empty day.
    static func parse(_ data: Data) -> [Batch] {
        guard !data.isEmpty else { return [] }
        let marker = Data(Self.usageKey.utf8)
        var batch = Batch()

        for line in data.split(separator: UInt8(ascii: "\n")) {
            // Cheap reject before the JSON parse: most records in a transcript are tool calls and
            // results, and only the ones carrying usage matter here.
            guard line.range(of: marker) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let providerData = object["providerData"] as? [String: Any],
                  let rawUsage = providerData[Self.usageKey] as? [String: Any]
            else { continue }

            guard let timestampMs = ProviderParse.number(object["timestamp"]),
                  timestampMs > 0,
                  let messageID = (providerData["messageId"] as? String)?
                      .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            else { continue }

            let model = modelName(providerData)
            let tokens = tokenBreakdown(rawUsage)
            guard tokens.totalTokens > 0 else { continue }

            batch.entries.append(Entry(
                messageID: messageID,
                timestamp: Date(timeIntervalSince1970: timestampMs / 1000),
                model: model,
                tokens: tokens
            ))
        }

        return [batch]
    }

    /// Which model id to report for a request. WorkBuddy records the routed model in `requestModelId`
    /// (e.g. `auto`) alongside the one that actually served the turn in `model`, so `model` wins; the
    /// request id is only the fallback for a record whose `model` is blank.
    private static func modelName(_ providerData: [String: Any]) -> String {
        for key in ["model", "requestModelId"] {
            if let value = (providerData[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return value
            }
        }
        return unknownModel
    }

    /// WorkBuddy reports OpenAI-style usage, where `prompt_tokens` **includes** the cached hits (it also
    /// publishes `prompt_cache_miss_tokens`, and that plus the hits adds up to `prompt_tokens`). Billing
    /// the whole prompt at the input rate would charge cached tokens twice, so the cached portion splits
    /// out into the cache-read bucket and only the remainder bills as plain input. Cache *writes* are
    /// their own counter when the provider reports one. The token total still matches WorkBuddy's own.
    static func tokenBreakdown(_ rawUsage: [String: Any]) -> TokenBreakdown {
        let prompt = boundedTokenCount(rawUsage["prompt_tokens"])
        let completion = boundedTokenCount(rawUsage["completion_tokens"])
        let cacheRead = min(boundedTokenCount(rawUsage["prompt_cache_hit_tokens"]), prompt)
        let remainingPrompt = prompt - cacheRead
        let cacheWrite = min(boundedTokenCount(rawUsage["prompt_cache_write_tokens"]), remainingPrompt)
        return TokenBreakdown(
            input: remainingPrompt - cacheWrite,
            cacheWrite5m: cacheWrite,
            cacheRead: cacheRead,
            output: completion
        )
    }

    /// `Int(Double)` traps above `Int.max`, and a corrupt count would otherwise crash the refresh.
    /// 1e15 is far above any real per-request token count.
    private static func boundedTokenCount(_ value: Any?) -> Int {
        Int(min(max(ProviderParse.number(value) ?? 0, 0), 1e15))
    }

    // MARK: - Aggregation

    /// Price the deduplicated requests into the daily series behind the spend tiles and the trend. A
    /// request whose model no pricing source can price is dropped from the totals and recorded as an
    /// unknown model for that day — the same contract every other local scanner follows.
    static func aggregate(entries: [Entry], since: Date, pricing: ModelPricing) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()

        for entry in entries {
            guard entry.timestamp >= since else { continue }
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            guard let cost = pricing.estimatedCostDollars(model: entry.model, tokens: entry.tokens) else {
                accumulator.addUnknownModel(day: day, model: entry.model)
                continue
            }
            accumulator.add(day: day, tokens: entry.tokens.totalTokens, cost: cost, model: entry.model)
        }
        return accumulator.build()
    }
}
