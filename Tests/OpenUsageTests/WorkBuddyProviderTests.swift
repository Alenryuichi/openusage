import XCTest
@testable import OpenUsage

/// End-to-end WorkBuddy provider behavior: first-run detection from local transcripts, the spend tiles
/// and trend, and the two failure paths (no WorkBuddy footprint, unreadable logs).
@MainActor
final class WorkBuddyProviderTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

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

    /// A provider wired to a fixed clock, the textbook pricing above, and an injected transcript list —
    /// so every test reads only its own fixture, never the real `~/.workbuddy` of the test machine.
    private func provider(logFiles: @escaping @Sendable (String) -> [String]) -> WorkBuddyProvider {
        let now = self.now
        let pricing = self.pricing
        return WorkBuddyProvider(
            usageScanner: WorkBuddyUsageScanner(
                environment: FakeEnvironment(["WORKBUDDY_HOME": "/tmp/workbuddy-fixture"]),
                homeDirectory: { URL(fileURLWithPath: "/tmp/workbuddy-fixture") },
                logFiles: logFiles
            ),
            pricing: { pricing },
            now: { now }
        )
    }

    func testDetectsUsageAndBacksTheSpendTilesAndTrend() async throws {
        let home = try WorkBuddyLogFixture.makeHome(files: [
            "workspace/session.jsonl": [
                workbuddyLine(messageID: "today", timestampMs: epochMs("2026-07-12T11:00:00Z"), prompt: 1000, completion: 500),
                workbuddyLine(messageID: "yesterday", timestampMs: epochMs("2026-07-11T11:00:00Z"), prompt: 2000, completion: 1000)
            ].joined(separator: "\n")
        ])
        let provider = provider(logFiles: { _ in WorkBuddyPaths.logFiles(in: home.path) })

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Today", "Yesterday", "Last 30 Days", "Usage Trend"])
    }

    func testSpendTilesFlagEstimatedDollarsButMeasuredTokens() async throws {
        let home = try WorkBuddyLogFixture.makeHome(files: [
            "workspace/session.jsonl": workbuddyLine(
                messageID: "today", timestampMs: epochMs("2026-07-12T11:00:00Z"), prompt: 1000, completion: 500
            )
        ])
        let provider = provider(logFiles: { _ in WorkBuddyPaths.logFiles(in: home.path) })

        let snapshot = await provider.refresh()

        guard case .values(let label, let values, _, _, _, _)? = snapshot.lines.first else {
            return XCTFail("expected a Today values row")
        }
        XCTAssertEqual(label, "Today")
        // Dollars are imputed locally (ⓘ); the token count is measured, so it is never flagged.
        XCTAssertEqual(values.map(\.estimated), [true, false])
        XCTAssertEqual(values.map(\.kind), [.dollars, .count])
        // 1000 in at $1/M + 500 out at $4/M.
        XCTAssertEqual(values[0].number, 0.003, accuracy: 1e-9)

        guard case .chart(_, _, let note)? = snapshot.lines.last else {
            return XCTFail("expected a Usage Trend chart row")
        }
        XCTAssertEqual(note, "From your WorkBuddy logs (estimated)")
    }

    func testErrorsWhenNoTranscriptsExist() async {
        let provider = provider(logFiles: { _ in [] })

        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertEqual(snapshot.lines.first?.label, MetricLine.errorBadgeLabel)
    }

    func testErrorsWhenEveryTranscriptIsUnreadable() async {
        let provider = provider(logFiles: { _ in ["/tmp/workbuddy-fixture/projects/gone.jsonl"] })

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(snapshot.errorMessageText, WorkBuddyUsageError.logsUnreadable.errorDescription)
    }

    func testIdleTranscriptsReadNoDataRatherThanAnError() async throws {
        let home = try WorkBuddyLogFixture.makeHome(files: [
            "workspace/session.jsonl": #"{"type":"message","timestamp":1784000000000,"role":"user"}"#
        ])
        let provider = provider(logFiles: { _ in WorkBuddyPaths.logFiles(in: home.path) })

        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines, [MetricLine.noUsageData])
    }

    func testUnpricedModelsRaiseTheSpendTileWarningTriangle() async throws {
        // WorkBuddy serves several in-house models no pricing source carries yet. Their tokens must not
        // be priced at zero silently — the day's row names them so the tile can show its warning
        // triangle, while the priced model on the same day still backs the dollars.
        let home = try WorkBuddyLogFixture.makeHome(files: [
            "workspace/session.jsonl": [
                workbuddyLine(
                    messageID: "priced", timestampMs: epochMs("2026-07-12T11:00:00Z"),
                    prompt: 1000, completion: 500
                ),
                workbuddyLine(
                    messageID: "unpriced", timestampMs: epochMs("2026-07-12T11:30:00Z"),
                    prompt: 900_000, completion: 1000, model: "hy4-preview"
                )
            ].joined(separator: "\n")
        ])
        let provider = provider(logFiles: { _ in WorkBuddyPaths.logFiles(in: home.path) })

        let snapshot = await provider.refresh()

        guard case .values(let label, let values, _, _, let unknownModels, _)? = snapshot.line(label: "Today") else {
            return XCTFail("expected a Today values row; got \(snapshot.lines.map(\.label))")
        }
        XCTAssertEqual(label, "Today")
        XCTAssertEqual(unknownModels, ["hy4-preview"])
        // Only the priced request is counted: 1000 in at $1/M + 500 out at $4/M, and its 1,500 tokens.
        // The unpriced model's 901,000 tokens stay out rather than being added at zero dollars.
        XCTAssertEqual(values.map(\.kind), [.dollars, .count])
        XCTAssertEqual(values[0].number, 0.003, accuracy: 1e-9)
        XCTAssertEqual(values[1].number, 1500)
    }

    private func epochMs(_ iso: String) -> Double {
        OpenUsageISO8601.date(from: iso)!.timeIntervalSince1970 * 1000
    }

    private func workbuddyLine(
        messageID: String,
        timestampMs: Double,
        prompt: Double,
        completion: Double,
        model: String = "glm-5.3"
    ) -> String {
        let record: [String: Any] = [
            "type": "function_call",
            "timestamp": timestampMs,
            "providerData": [
                "messageId": messageID,
                "model": model,
                "agent": "cli",
                "rawUsage": [
                    "prompt_tokens": prompt,
                    "completion_tokens": completion,
                    "total_tokens": prompt + completion,
                    "prompt_cache_hit_tokens": 0,
                    "prompt_cache_write_tokens": 0
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}

private extension ProviderSnapshot {
    /// The user-facing text on an error snapshot's badge, for asserting the typed failure surfaced.
    var errorMessageText: String? {
        guard case .badge(let label, let text, _, _)? = lines.first, label == MetricLine.errorBadgeLabel else {
            return nil
        }
        return text
    }
}
