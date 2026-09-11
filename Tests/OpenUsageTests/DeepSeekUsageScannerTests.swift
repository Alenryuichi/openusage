import XCTest
@testable import OpenUsage

// MARK: - DeepSeekPricing

final class DeepSeekPricingTests: XCTestCase {
    func testPeakWindowIsUTCMondayToFriday0100To0400And0600To1000() {
        // 2026-07-13 is a Monday. 03:00 UTC is inside the first window, 04:00 is not.
        XCTAssertTrue(DeepSeekPricing.isPeak(iso("2026-07-13T03:00:00Z")))
        XCTAssertFalse(DeepSeekPricing.isPeak(iso("2026-07-13T04:00:00Z")))
        // 07:00 UTC is inside the second window, 10:00 is not.
        XCTAssertTrue(DeepSeekPricing.isPeak(iso("2026-07-13T07:00:00Z")))
        XCTAssertFalse(DeepSeekPricing.isPeak(iso("2026-07-13T10:00:00Z")))
        // The whole 00:00 hour is off-peak.
        XCTAssertFalse(DeepSeekPricing.isPeak(iso("2026-07-13T00:30:00Z")))
        // Weekends are off-peak even inside the hours.
        XCTAssertFalse(DeepSeekPricing.isPeak(iso("2026-07-12T03:00:00Z")))   // Sunday
        XCTAssertFalse(DeepSeekPricing.isPeak(iso("2026-07-11T07:00:00Z")))   // Saturday
        // An afternoon weekday is off-peak.
        XCTAssertFalse(DeepSeekPricing.isPeak(iso("2026-07-13T15:00:00Z")))
    }

    func testOffPeakIsExactlyHalfOfPeak() throws {
        let table = try XCTUnwrap(DeepSeekPricing.rates(for: "deepseek-flash"))
        XCTAssertEqual(table.offPeak.inputPerMillion, table.peak.inputPerMillion / 2)
        XCTAssertEqual(table.offPeak.cacheReadPerMillion, table.peak.cacheReadPerMillion / 2)
        XCTAssertEqual(table.offPeak.outputPerMillion, table.peak.outputPerMillion / 2)
    }

    func testRetiredFlashNamesShareTheFlashRateAndUnknownModelsAreUnpriced() {
        let flash = DeepSeekPricing.rates(for: "deepseek-flash")?.peak
        XCTAssertEqual(DeepSeekPricing.rates(for: "deepseek-v4-flash")?.peak, flash)
        XCTAssertEqual(DeepSeekPricing.rates(for: "deepseek-v4-flash-vision-exp")?.peak, flash)
        XCTAssertNotNil(DeepSeekPricing.rates(for: "deepseek-v4-pro"))
        XCTAssertNil(DeepSeekPricing.rates(for: "gpt-5"))
    }

    func testCostUsesTheTierOfTheRequestInstant() throws {
        // 1M uncached input + 1M output, priced at the published Flash rates.
        let tokens = TokenBreakdown(input: 1_000_000, output: 1_000_000)
        let peak = try XCTUnwrap(DeepSeekPricing.cost(
            for: "deepseek-flash", tokens: tokens, at: iso("2026-07-13T03:00:00Z")
        ))
        let offPeak = try XCTUnwrap(DeepSeekPricing.cost(
            for: "deepseek-flash", tokens: tokens, at: iso("2026-07-13T15:00:00Z")
        ))

        XCTAssertEqual(peak, 0.30 + 1.20, accuracy: 1e-9)
        XCTAssertEqual(offPeak, 0.15 + 0.60, accuracy: 1e-9)
    }

    /// The numbers this card exists to get right: cache reads dominate an agent's traffic, and they bill
    /// at a different rate from uncached input.
    func testCacheReadsBillAtTheCacheRateNotTheInputRate() throws {
        let tokens = TokenBreakdown(input: 1_000_000, cacheRead: 1_000_000)
        let offPeak = try XCTUnwrap(DeepSeekPricing.cost(
            for: "deepseek-flash", tokens: tokens, at: iso("2026-07-13T15:00:00Z")
        ))
        XCTAssertEqual(offPeak, 0.15 + 0.003, accuracy: 1e-9)
    }

    func testUnknownModelIsUnpriced() {
        XCTAssertNil(DeepSeekPricing.cost(
            for: "mystery-model", tokens: TokenBreakdown(input: 10), at: iso("2026-07-13T15:00:00Z")
        ))
    }

    private func iso(_ value: String) -> Date { OpenUsageISO8601.date(from: value)! }
}

// MARK: - DSH credential discovery

final class DeepSeekDSHCredentialTests: XCTestCase {
    /// The real layout, including a *different* secret in the same file, which must never be returned.
    private let credentials = """
    version: 1
    records:
      client-connection/browser-session:
        kind: grant
        payload:
          version: 1
          secret: P2zPMjQxNzc5Nzc2NDk5NDcx
    refs:
      DEEPSEEK_API_KEY: sk-f173f0000000000000000000000002bbf
      OTHER_KEY: nope
    """

    func testReadsTheDeepSeekRefOutOfTheRefsBlock() {
        XCTAssertEqual(
            DeepSeekAuthStore.reference(inCredentials: credentials, named: "DEEPSEEK_API_KEY"),
            "sk-f173f0000000000000000000000002bbf"
        )
    }

    func testNeverReturnsAnotherBlockSecret() {
        // The browser-session secret is nested under `records`, not `refs` — the strict scan must ignore
        // it even though `secret:` looks like a key line.
        XCTAssertNil(DeepSeekAuthStore.reference(inCredentials: credentials, named: "secret"))
        XCTAssertNil(DeepSeekAuthStore.reference(inCredentials: credentials, named: "version"))
        XCTAssertNil(DeepSeekAuthStore.reference(inCredentials: credentials, named: "kind"))
    }

    func testStopsAtTheNextTopLevelBlock() {
        let text = """
        refs:
          DEEPSEEK_API_KEY: sk-real
        other-block:
          DEEPSEEK_API_KEY: sk-decoy
        """
        XCTAssertEqual(DeepSeekAuthStore.reference(inCredentials: text, named: "DEEPSEEK_API_KEY"), "sk-real")
    }

    func testHandlesQuotedAndMissingValues() {
        XCTAssertEqual(
            DeepSeekAuthStore.reference(inCredentials: "refs:\n  DEEPSEEK_API_KEY: \"sk-quoted\"\n", named: "DEEPSEEK_API_KEY"),
            "sk-quoted"
        )
        XCTAssertNil(DeepSeekAuthStore.reference(inCredentials: "refs:\n  DEEPSEEK_API_KEY:\n", named: "DEEPSEEK_API_KEY"))
        XCTAssertNil(DeepSeekAuthStore.reference(inCredentials: "version: 1\n", named: "DEEPSEEK_API_KEY"))
    }

    func testAuthStoreDiscoversTheKeyFromDSH() {
        let files = FakeFiles([DeepSeekPaths.credentialsFile(home: "/tmp/dsh"): credentials])
        let store = DeepSeekAuthStore(
            files: files,
            environment: FakeEnvironment(["DSH_HOME": "/tmp/dsh"]),
            homeDirectory: { URL(fileURLWithPath: "/tmp/dsh") }
        )
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-f173f0000000000000000000000002bbf")
        // Discovered, not saved here: the editor reports it as coming from elsewhere.
        XCTAssertEqual(store.keyStatus(), .fromEnvironment)
    }

    func testAnExplicitConfigFileWinsOverTheDiscoveredKey() throws {
        let files = FakeFiles([
            DeepSeekPaths.credentialsFile(home: "/tmp/dsh"): credentials,
            DeepSeekAuthStore.configPaths[0]: #"{"apiKey":"sk-mine"}"#
        ])
        let store = DeepSeekAuthStore(
            files: files,
            environment: FakeEnvironment(["DSH_HOME": "/tmp/dsh"]),
            homeDirectory: { URL(fileURLWithPath: "/tmp/dsh") }
        )
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-mine")
        XCTAssertEqual(store.keyStatus(), .overrideActive)
    }

    func testDSHHomeOverrideIsHonoured() {
        let files = FakeFiles([DeepSeekPaths.credentialsFile(home: "/custom/dsh"): credentials])
        let store = DeepSeekAuthStore(
            files: files,
            environment: FakeEnvironment(["DSH_HOME": "/custom/dsh"]),
            homeDirectory: { URL(fileURLWithPath: "/tmp/home") }
        )
        XCTAssertNotNil(store.loadAPIKey())
    }
}

// MARK: - zstd reader

final class ZstdLineReaderTests: XCTestCase {
    func testDecompressesASingleFrameRecordByRecord() throws {
        let lines = try readLines(base64: Self.singleFrame)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].contains(#""type":"session""#))
        XCTAssertTrue(lines[1].contains(#""id":"msg-a""#))
    }

    func testWalksConcatenatedFrames() throws {
        // DSH appends frames as a session grows, so a log is not always one frame.
        let lines = try readLines(base64: Self.twoFrames)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[3].contains(#""id":"msg-b""#))
    }

    func testBodyCanStopEarly() throws {
        let path = try writeFixture(base64: Self.singleFrame)
        var seen = 0
        let completed = try ZstdLineReader.forEachLine(at: path) { _ in
            seen += 1
            return seen < 2
        }
        XCTAssertFalse(completed)
        XCTAssertEqual(seen, 2)
    }

    func testCorruptInputThrowsInsteadOfReturningGarbage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-corrupt-\(UUID().uuidString).jsonl.zstd")
        try Data("this is not zstd at all".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try ZstdLineReader.forEachLine(at: url.path) { _ in true })
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try ZstdLineReader.forEachLine(at: "/tmp/definitely-not-here-\(UUID().uuidString)") { _ in true })
    }

    // MARK: - Helpers

    /// One frame holding a session header, two assistant messages (Flash and Pro), and a tool call.
    private static let singleFrame =
        "KLUv/WD6AQ0KAEYRNiFAh1gHc1zcr3ylFBW4GAIEj3EwR98Cq4Mtvh1xRtHhzgUrACsALAAnOOIjj7c7A80b7SrVeWJqLWZhBsUsDGnfx8kn1S6w/XTIrnv77RsL5BsB7dA6jsFQbKCIH0NPV0KiH/dGiyv7CWmHUCSXUgjDkE1o9z6HhCrbdetgzovCEuSp5ESRET8VWFJob7gLDpBRhNHTnFe0PsRbh5+nP3WNQyCYsNjtuOs8gzmnUsliKBIUxmGppbAOV6iUQtR6T5vjMcu5lJWADnLrQk+GhGGOLsAqGm2eAiogYCIpk/aBJELYCaZwhbro4TowVAWAcGG10UPhwbpVW6AWYGQcDAWGBRpuAGRwqAJuI5w4hvfklBMqUq0SkKQMVcAPYzgBZLw8X/k1m8wXuCuwaV7OUpEJ4O7P0NYdryaLLMUxAw=="
    /// The same records split across two concatenated frames.
    private static let twoFrames =
        "KLUv/SDI9QMA8gcZGmBp3ABdxe4PUcR+9mQQBBnbp8C2sAABYOGIxxOQ5HgNHNzYlXzbfER5lxg6nYOWQnso8zbTTpsZswKW5QjzWpvnjcPgSl5bjaM6Ka1CCc4qFMpvY308+cLy8Q5hzMvP70v0lQgAbpyXI1ARCGC5HwxtRcerIIssRTADKLUv/WAyAWUIAMKPLyBApbgNY49fduu3waVGBQgu13UM9wZB/iPY0nsqysIrAoL3XkpKsg4aLA627vjEYMHP1Z1jog5p8xFRby7qdCiwPoRu2byYM/Fs2ekcU0oIgmAMCXFgEHV9Vh9Toi6gfDxj2RDYbl9doYH+Q/DeS5Zk0VZbTnVHg4JgnFQAZTTZHA8LoyAse/vIKEtHeywwSkGdmzY2oCOorUVydHzvDE6mYOrsczzL1SyFYgcNVYZUnas7dZZjHfSHujYuWg4dAIGbCOGaYCNcIV303nWAobIAEG5YHlwHsMANBXBmZbF2KQIxsEWFoIGUKh5ANfFN7AA0g4EGdrUJkE5S7SQgKdLdWGPgS/m5WQY="

    private func writeFixture(base64: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-zstd-\(UUID().uuidString).jsonl.zstd")
        try XCTUnwrap(Data(base64Encoded: base64)).write(to: url)
        return url.path
    }

    private func readLines(base64: String) throws -> [String] {
        let path = try writeFixture(base64: base64)
        defer { try? FileManager.default.removeItem(atPath: path) }
        var lines: [String] = []
        try ZstdLineReader.forEachLine(at: path) { line in
            lines.append(String(decoding: Data(line), as: UTF8.self))
            return true
        }
        return lines
    }
}

// MARK: - DeepSeekUsageScanner

final class DeepSeekUsageScannerTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!
    private let since = OpenUsageISO8601.date(from: "2026-06-12T00:00:00.000Z")!

    func testParsesTheUsageAndModelFromAnAssistantRecord() throws {
        let entry = try XCTUnwrap(DeepSeekUsageScanner.parse(line(
            type: "assistant/message",
            ms: 1_784_000_000_000,
            id: "msg-1",
            model: "deepseek-flash",
            input: 5375, cacheRead: 7936, output: 437
        )))

        XCTAssertEqual(entry.messageID, "msg-1")
        XCTAssertEqual(entry.model, "deepseek-flash")
        // `inputTokens` is the uncached prompt, so the buckets are disjoint and sum to the real total.
        XCTAssertEqual(entry.tokens.input, 5375)
        XCTAssertEqual(entry.tokens.cacheRead, 7936)
        XCTAssertEqual(entry.tokens.output, 437)
        XCTAssertEqual(entry.tokens.totalTokens, 13_748)
    }

    func testIgnoresRecordsThatAreNotCompletedAssistantMessages() throws {
        XCTAssertNil(DeepSeekUsageScanner.parse(line(type: "tool/call", ms: 1, id: "x", model: "m", input: 1)))
        // An assistant message with no usage block (a streaming delta) is not a request.
        let noUsage = #"{"type":"assistant/message","seq":3,"time":1784000000000,"data":{"message":{"id":"a"}}}"#
        XCTAssertNil(DeepSeekUsageScanner.parse(Data(noUsage.utf8).withUnsafeBytes { $0 }))
        // Malformed JSON.
        XCTAssertNil(DeepSeekUsageScanner.parse(Data("{oops".utf8).withUnsafeBytes { $0 }))
    }

    func testPricingFollowsEachRequestsOwnTimestamp() throws {
        // Two identical requests that must bucket into one local day and each pay the off-peak rate. The
        // tier rule itself is covered by `DeepSeekPricingTests`; what this pins is that per-request pricing
        // adds up rather than being applied once per day.
        //
        // Both carry the *same* instant, so no time zone can split them across a local midnight — pinning
        // hours is exactly what makes this kind of test pass in one zone and fail in another. 12:30Z is
        // 20:00–22:00 UTC on Monday 2026-07-13, outside both peak windows in every zone.
        let first = try XCTUnwrap(DeepSeekUsageScanner.parse(line(
            type: "assistant/message", ms: epochMs("2026-07-13T12:30:00Z"),
            id: "first", model: "deepseek-flash", input: 1_000_000, cacheRead: 0, output: 0
        )))
        let second = try XCTUnwrap(DeepSeekUsageScanner.parse(line(
            type: "assistant/message", ms: epochMs("2026-07-13T12:30:00Z"),
            id: "second", model: "deepseek-flash", input: 1_000_000, cacheRead: 0, output: 0
        )))

        let scan = DeepSeekUsageScanner.aggregate(entries: [first, second], since: since)
        let day = try XCTUnwrap(scan.series.daily.first)

        XCTAssertEqual(day.date, DailyUsageAccumulator.dayKey(from: first.timestamp))
        XCTAssertEqual(day.costUSD ?? 0, 2 * 0.15, accuracy: 1e-9)
        XCTAssertEqual(day.totalTokens, 2_000_000)
    }

    func testUnpricedModelIsFlaggedInsteadOfCountedAtZero() throws {
        let known = try XCTUnwrap(DeepSeekUsageScanner.parse(line(
            type: "assistant/message", ms: epochMs("2026-07-13T15:00:00Z"),
            id: "known", model: "deepseek-flash", input: 1_000_000, cacheRead: 0, output: 0
        )))
        let unknown = try XCTUnwrap(DeepSeekUsageScanner.parse(line(
            type: "assistant/message", ms: epochMs("2026-07-13T15:00:00Z"),
            id: "unknown", model: "deepseek-something-new", input: 5000, cacheRead: 0, output: 0
        )))

        let scan = DeepSeekUsageScanner.aggregate(entries: [known, unknown], since: since)
        let day = try XCTUnwrap(scan.series.daily.first)

        XCTAssertEqual(day.totalTokens, 1_000_000)
        XCTAssertEqual(
            scan.unknownModelsByDay[DailyUsageAccumulator.dayKey(from: known.timestamp)],
            ["deepseek-something-new"]
        )
    }

    func testRequestsBeforeTheWindowAreDropped() throws {
        // The cutoff is derived from the fixture itself rather than hardcoded, so the assertions hold in
        // any time zone: the window covers the recent request and not the older one.
        let recent = try XCTUnwrap(DeepSeekUsageScanner.parse(line(
            type: "assistant/message", ms: epochMs("2026-07-12T12:00:00Z"),
            id: "recent", model: "deepseek-flash", input: 100, cacheRead: 0, output: 0
        )))
        let old = try XCTUnwrap(DeepSeekUsageScanner.parse(line(
            type: "assistant/message", ms: epochMs("2026-05-01T12:00:00Z"),
            id: "old", model: "deepseek-flash", input: 100, cacheRead: 0, output: 0
        )))
        let cutoff = recent.timestamp.addingTimeInterval(-36 * 3600)

        let scan = DeepSeekUsageScanner.aggregate(entries: [old, recent], since: cutoff)

        XCTAssertEqual(scan.series.daily.map(\.date), [DailyUsageAccumulator.dayKey(from: recent.timestamp)])
    }

    func testScanReadsATemporaryDSHHomeAndDedupesReplayedRequests() async throws {
        let home = try DeepSeekLogFixture.makeHome([
            "Users-me-app/session-abc/session.v3.jsonl.zstd": DeepSeekLogFixture.singleFrameBase64,
            // A forked session replaying the same request must not count it twice.
            "Users-me-app/session-def/session.v3.jsonl.zstd": DeepSeekLogFixture.singleFrameBase64
        ])
        let scanner = DeepSeekUsageScanner(
            environment: FakeEnvironment(["DSH_HOME": home.path]),
            homeDirectory: { home },
            sessionLogFiles: { DeepSeekPaths.sessionLogFiles(home: $0) }
        )

        let scan = try await scanner.scan(now: now)
        let day = try XCTUnwrap(scan?.series.daily.first)

        // msg-a: 13,748 tokens (dense prompt); msg-b: 3,000. Replayed copies are dropped entirely.
        XCTAssertEqual(day.totalTokens, 13_748 + 3000)
        XCTAssertNotNil(day.costUSD)
        let detected = await scanner.hasSessionUsage()
        XCTAssertTrue(detected)
    }

    func testScanReturnsNilWithoutSessionLogs() async throws {
        let home = try DeepSeekLogFixture.makeHome([:])
        let scanner = DeepSeekUsageScanner(
            environment: FakeEnvironment(["DSH_HOME": home.path]),
            homeDirectory: { home },
            sessionLogFiles: { DeepSeekPaths.sessionLogFiles(home: $0) }
        )

        let scan = try await scanner.scan(now: now)
        XCTAssertNil(scan)
        let detected = await scanner.hasSessionUsage()
        XCTAssertFalse(detected)
    }

    // MARK: - Helpers

    private func epochMs(_ iso: String) -> Double {
        OpenUsageISO8601.date(from: iso)!.timeIntervalSince1970 * 1000
    }

    private func line(
        type: String,
        ms: Double,
        id: String,
        model: String = "deepseek-flash",
        input: Double = 0,
        cacheRead: Double = 0,
        output: Double = 0
    ) -> UnsafeRawBufferPointer {
        let record: [String: Any] = [
            "type": type,
            "seq": 1,
            "time": ms,
            "data": [
                "message": ["id": id, "role": "assistant", "source": ["provider": "deepseek-official", "model": model]],
                "usage": [
                    "inputTokens": input,
                    "cacheReadTokens": cacheRead,
                    "cacheWriteTokens": 0,
                    "outputTokens": output,
                    "totalTokens": input + cacheRead + output
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        return data.withUnsafeBytes { $0 }
    }
}

/// Builds a throwaway DSH home (`<tmp>/…/sessions/<project>/<session>/session.v3.jsonl.zstd`) so the
/// scanner reads only the fixture and never the real `~/.dsh` of the machine running the tests.
enum DeepSeekLogFixture {
    /// Base64 of a zstd frame holding two assistant messages: `deepseek-flash` (13,748 tokens) and
    /// `deepseek-v4-pro` (3,000 tokens), plus a session header and a tool call.
    static let singleFrameBase64 =
        "KLUv/WD6AQ0KAEYRNiFAh1gHc1zcr3ylFBW4GAIEj3EwR98Cq4Mtvh1xRtHhzgUrACsALAAnOOIjj7c7A80b7SrVeWJqLWZhBsUsDGnfx8kn1S6w/XTIrnv77RsL5BsB7dA6jsFQbKCIH0NPV0KiH/dGiyv7CWmHUCSXUgjDkE1o9z6HhCrbdetgzovCEuSp5ESRET8VWFJob7gLDpBRhNHTnFe0PsRbh5+nP3WNQyCYsNjtuOs8gzmnUsliKBIUxmGppbAOV6iUQtR6T5vjMcu5lJWADnLrQk+GhGGOLsAqGm2eAiogYCIpk/aBJELYCaZwhbro4TowVAWAcGG10UPhwbpVW6AWYGQcDAWGBRpuAGRwqAJuI5w4hvfklBMqUq0SkKQMVcAPYzgBZLw8X/k1m8wXuCuwaV7OUpEJ4O7P0NYdryaLLMUxAw=="

    static func makeHome(_ files: [String: String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-dsh-\(UUID().uuidString)", isDirectory: true)
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        for (relativePath, base64) in files {
            let file = sessions.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(Data(base64Encoded: base64)).write(to: file)
        }
        return home
    }
}
