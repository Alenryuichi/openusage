import Foundation
import XCTest
@testable import OpenUsage

/// The WorkBuddy transcript scanner: parses request-level `providerData.rawUsage` out of the agent's
/// session JSONL, dedupes replayed records, prices each request into the daily series behind the spend
/// tiles and trend, and flags models no pricing source knows.
final class WorkBuddyUsageScannerTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!
    private let since = OpenUsageISO8601.date(from: "2026-06-12T00:00:00.000Z")!

    /// Textbook rates: $1 per million in, $4 out, $0.25 cache read, $1 cache write — so expected costs
    /// read off by hand.
    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "glm-5.3": ModelRates(
                inputPerMillion: 1, outputPerMillion: 4,
                cacheWritePerMillion: 1, cacheReadPerMillion: 0.25
            )
        ]),
        secondary: PricingCatalog()
    )

    // MARK: - Parsing

    func testParsesRequestLevelUsageAndSplitsCachedPromptOutOfInput() throws {
        // WorkBuddy reports `prompt_tokens` inclusive of the cache hits (33764 = 128 hit + 33636 miss),
        // so only the miss bills as plain input; the hit bills at the cache-read rate.
        let entries = try parsedEntries(line(
            messageID: "msg-1",
            timestampMs: 1_784_000_000_000,
            model: "glm-5.3",
            prompt: 33_764,
            completion: 255,
            cacheHit: 128
        ))

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.messageID, "msg-1")
        XCTAssertEqual(entry.model, "glm-5.3")
        XCTAssertEqual(entry.tokens.cacheRead, 128)
        XCTAssertEqual(entry.tokens.input, 33_636)
        XCTAssertEqual(entry.tokens.output, 255)
        XCTAssertEqual(entry.tokens.cacheWrite5m, 0)
        // The total still matches what WorkBuddy itself recorded.
        XCTAssertEqual(entry.tokens.totalTokens, 34_019)
    }

    func testCacheWriteTokensGetTheirOwnBucket() throws {
        let entries = try parsedEntries(line(
            messageID: "msg-write",
            timestampMs: 1_784_000_000_000,
            model: "glm-5.3",
            prompt: 1000,
            completion: 10,
            cacheHit: 200,
            cacheWrite: 300
        ))

        let tokens = try XCTUnwrap(entries.first).tokens
        XCTAssertEqual(tokens.cacheRead, 200)
        XCTAssertEqual(tokens.cacheWrite5m, 300)
        XCTAssertEqual(tokens.input, 500)
        XCTAssertEqual(tokens.totalTokens, 1010)
    }

    func testSkipsRecordsWithoutUsageMessageIDOrTimestamps() throws {
        var lines = [
            // A tool call with no `providerData.rawUsage` block — most of a transcript's records.
            #"{"type":"function_call_result","timestamp":1784000000000,"name":"bash"}"#,
            // Usage but no message id: nothing stable to dedupe on.
            #"{"type":"message","timestamp":1784000000000,"providerData":{"rawUsage":{"prompt_tokens":10,"completion_tokens":1}}}"#,
            // Usage but no timestamp.
            #"{"type":"message","providerData":{"messageId":"m","rawUsage":{"prompt_tokens":10,"completion_tokens":1}}}"#,
            // A request that moved no tokens (an errored or cancelled call the provider still logged).
            line(messageID: "zero", timestampMs: 1_784_000_000_000, model: "glm-5.3", prompt: 0, completion: 0),
            // Malformed JSON.
            "{not json"
        ]
        lines.append(line(messageID: "real", timestampMs: 1_784_000_000_000, model: "glm-5.3", prompt: 100, completion: 10))

        let entries = try parsedEntries(lines.joined(separator: "\n"))
        XCTAssertEqual(entries.map(\.messageID), ["real"])
    }

    func testModelFallsBackToRequestModelIDThenUnknown() throws {
        let explicit = try parsedEntries(
            #"{"type":"message","timestamp":1784000000000,"providerData":{"messageId":"a","model":"glm-5.3","requestModelId":"auto","rawUsage":{"prompt_tokens":10,"completion_tokens":1}}}"#
        )
        XCTAssertEqual(explicit.first?.model, "glm-5.3")

        let routed = try parsedEntries(
            #"{"type":"message","timestamp":1784000000000,"providerData":{"messageId":"b","model":"","requestModelId":"auto","rawUsage":{"prompt_tokens":10,"completion_tokens":1}}}"#
        )
        XCTAssertEqual(routed.first?.model, "auto")

        let unknown = try parsedEntries(
            #"{"type":"message","timestamp":1784000000000,"providerData":{"messageId":"c","rawUsage":{"prompt_tokens":10,"completion_tokens":1}}}"#
        )
        XCTAssertEqual(unknown.first?.model, WorkBuddyUsageScanner.unknownModel)
    }

    // MARK: - Aggregation

    func testPricesRequestsIntoLocalDaysAndSumsThem() throws {
        // Both recent requests share one instant, so no time zone can split them across a local midnight —
        // pinning hours is what makes this kind of test fail somewhere in the world. The older request is
        // a full day earlier, which is a different local day in every zone. Assertions read the same local
        // calendar the scanner uses rather than hardcoding a date.
        let recent = try XCTUnwrap(parsedEntries(line(
            messageID: "recent-1", timestampMs: epochMs("2026-07-12T12:00:00.000Z"),
            model: "glm-5.3", prompt: 1000, completion: 500
        )).first)
        let recentSecond = try XCTUnwrap(parsedEntries(line(
            messageID: "recent-2", timestampMs: epochMs("2026-07-12T12:00:00.000Z"),
            model: "glm-5.3", prompt: 33_764, completion: 255, cacheHit: 128
        )).first)
        let older = try XCTUnwrap(parsedEntries(line(
            messageID: "older", timestampMs: epochMs("2026-07-11T12:00:00.000Z"),
            model: "glm-5.3", prompt: 2000, completion: 1000
        )).first)

        let scan = WorkBuddyUsageScanner.aggregate(entries: [recent, recentSecond, older], since: since, pricing: pricing)
        let recentDay = try XCTUnwrap(scan.series.daily.first { $0.date == DailyUsageAccumulator.dayKey(from: recent.timestamp) })
        let olderDay = try XCTUnwrap(scan.series.daily.first { $0.date == DailyUsageAccumulator.dayKey(from: older.timestamp) })

        // Recent: (1000 in + 500 out) and (33,636 in + 128 cache read + 255 out) at the rates above.
        let expectedRecent = 0.001 + 0.002 + 0.033_636 + 0.000_032 + 0.001_020
        XCTAssertEqual(recentDay.costUSD ?? 0, expectedRecent, accuracy: 1e-9)
        XCTAssertEqual(recentDay.totalTokens, 1500 + 34_019)
        XCTAssertEqual(olderDay.totalTokens, 3000)
        XCTAssertEqual(olderDay.costUSD ?? 0, 0.002 + 0.004, accuracy: 1e-9)
    }

    func testUnpricedModelIsExcludedAndFlaggedInsteadOfPricedAtZero() throws {
        let known = try XCTUnwrap(parsedEntries(line(
            messageID: "known", timestampMs: epochMs("2026-07-12T12:00:00.000Z"),
            model: "glm-5.3", prompt: 1000, completion: 500
        )).first)
        let unknown = try XCTUnwrap(parsedEntries(line(
            messageID: "unknown", timestampMs: epochMs("2026-07-12T12:00:00.000Z"),
            model: "hy4-preview", prompt: 900_000, completion: 1000
        )).first)

        let scan = WorkBuddyUsageScanner.aggregate(entries: [known, unknown], since: since, pricing: pricing)
        let day = try XCTUnwrap(scan.series.daily.first)

        XCTAssertEqual(day.totalTokens, 1500)
        XCTAssertEqual(day.costUSD ?? 0, 0.003, accuracy: 1e-9)
        XCTAssertEqual(
            scan.unknownModelsByDay[DailyUsageAccumulator.dayKey(from: known.timestamp)],
            ["hy4-preview"]
        )
    }

    func testRequestsBeforeTheWindowAreDropped() throws {
        // The cutoff is derived from the fixture rather than hardcoded, so the window's behaviour is what
        // is asserted — not the time zone the test happens to run in.
        let recent = try XCTUnwrap(parsedEntries(line(
            messageID: "recent", timestampMs: epochMs("2026-07-12T14:00:00.000Z"),
            model: "glm-5.3", prompt: 100, completion: 10
        )).first)
        let old = try XCTUnwrap(parsedEntries(line(
            messageID: "old", timestampMs: epochMs("2026-05-01T14:00:00.000Z"),
            model: "glm-5.3", prompt: 1000, completion: 500
        )).first)
        let cutoff = recent.timestamp.addingTimeInterval(-36 * 3600)

        let scan = WorkBuddyUsageScanner.aggregate(entries: [recent, old], since: cutoff, pricing: pricing)

        XCTAssertEqual(scan.series.daily.map(\.date), [DailyUsageAccumulator.dayKey(from: recent.timestamp)])
    }

    // MARK: - End-to-end scan over a temporary home

    func testScanReadsATemporaryHomeAndDedupesReplayedRequests() async throws {
        let request = line(messageID: "replayed", timestampMs: epochMs("2026-07-12T10:00:00.000Z"),
                           model: "glm-5.3", prompt: 1000, completion: 500)
        let home = try WorkBuddyLogFixture.makeHome(files: [
            "Users-me-Documents-app/session-a.jsonl": [
                #"{"type":"function_call","timestamp":1784000000000,"name":"bash"}"#,
                request
            ].joined(separator: "\n"),
            // A forked session replays the same request: its message id must not be counted twice.
            "Users-me-Documents-app/session-b.jsonl": request
        ])

        let scanner = WorkBuddyUsageScanner(
            environment: FakeEnvironment(["WORKBUDDY_HOME": home.path]),
            homeDirectory: { home },
            logFiles: { WorkBuddyPaths.logFiles(in: $0) }
        )
        let scan = try await scanner.scan(now: now, pricing: pricing)

        let today = try XCTUnwrap(scan?.series.daily.first)
        XCTAssertEqual(today.totalTokens, 1500)
        XCTAssertEqual(today.costUSD ?? 0, 0.003, accuracy: 1e-9)
        let detected = await scanner.hasModelUsage()
        XCTAssertTrue(detected)
    }

    func testScanReturnsNilWhenNoTranscriptsExist() async throws {
        let home = try WorkBuddyLogFixture.makeHome(files: [:])
        let scanner = WorkBuddyUsageScanner(
            environment: FakeEnvironment(["WORKBUDDY_HOME": home.path]),
            homeDirectory: { home },
            logFiles: { WorkBuddyPaths.logFiles(in: $0) }
        )

        let scan = try await scanner.scan(now: now, pricing: pricing)
        XCTAssertNil(scan)
        let detected = await scanner.hasModelUsage()
        XCTAssertFalse(detected)
    }

    func testTranscriptWithoutUsageDoesNotCountAsAFootprint() async throws {
        let home = try WorkBuddyLogFixture.makeHome(files: [
            "workspace/session.jsonl": #"{"type":"message","timestamp":1784000000000,"role":"user"}"#
        ])
        let scanner = WorkBuddyUsageScanner(
            environment: FakeEnvironment(["WORKBUDDY_HOME": home.path]),
            homeDirectory: { home },
            logFiles: { WorkBuddyPaths.logFiles(in: $0) }
        )

        let detected = await scanner.hasModelUsage()
        XCTAssertFalse(detected)
    }

    // MARK: - Helpers

    /// One WorkBuddy transcript record, shaped like the real thing (usage nested under `providerData`).
    private func line(
        messageID: String,
        timestampMs: Double,
        model: String,
        prompt: Double,
        completion: Double,
        cacheHit: Double = 0,
        cacheWrite: Double = 0
    ) -> String {
        let usage: [String: Any] = [
            "prompt_tokens": prompt,
            "completion_tokens": completion,
            "total_tokens": prompt + completion,
            "prompt_cache_hit_tokens": cacheHit,
            "prompt_cache_miss_tokens": prompt - cacheHit,
            "prompt_cache_write_tokens": cacheWrite,
            "cached_tokens": 0,
            "credit": 0
        ]
        let record: [String: Any] = [
            "type": "function_call",
            "timestamp": timestampMs,
            "providerData": [
                "messageId": messageID,
                "model": model,
                "requestModelId": "auto",
                "agent": "cli",
                "rawUsage": usage
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    private func parsedEntries(_ text: String) throws -> [WorkBuddyUsageScanner.Entry] {
        WorkBuddyUsageScanner.parse(Data(text.utf8)).flatMap(\.entries)
    }

    private func epochMs(_ iso: String) -> Double {
        OpenUsageISO8601.date(from: iso)!.timeIntervalSince1970 * 1000
    }
}

/// Builds throwaway WorkBuddy homes (`<tmp>/…/projects/<workspace>/<session>.jsonl`) so the scanner
/// reads only the fixture and never the real `~/.workbuddy` of the machine running the tests.
enum WorkBuddyLogFixture {
    static func makeHome(files: [String: String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-workbuddy-\(UUID().uuidString)", isDirectory: true)
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        for (relativePath, contents) in files {
            let file = projects.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        return home
    }
}
