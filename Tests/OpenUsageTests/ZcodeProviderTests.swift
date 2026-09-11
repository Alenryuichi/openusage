import XCTest
@testable import OpenUsage

/// End-to-end provider behavior: first-run detection from local usage, the spend tiles + trend, and the
/// two failure paths (no Zcode footprint, unreadable database).
@MainActor
final class ZcodeProviderTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!
    private let databasePath = "~/.zcode/cli/db/db.sqlite"

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

    private var usageDatabase: String {
        "[" + [
            zcodeRow("2026-07-12T11:00:00.000Z", "glm-5.3", input: 1000, output: 500),
            zcodeRow("2026-07-11T11:00:00.000Z", "glm-5.3", input: 2000, output: 1000)
        ].joined(separator: ",") + "]"
    }

    private func provider(
        data: [String: String] = [:],
        failing: Set<String> = [],
        databasePaths: [String]? = nil
    ) -> ZcodeProvider {
        let now = self.now
        let pricing = self.pricing
        return ZcodeProvider(
            usageScanner: ZcodeUsageScanner(
                sqlite: ZcodeFakeSQLite(data: data, failing: failing),
                databasePaths: { databasePaths ?? Array(data.keys) }
            ),
            pricing: { pricing },
            now: { now }
        )
    }

    func testHasLocalCredentialsViaLocalUsageButNotForEmptyDatabase() async {
        let detected = await provider(data: [databasePath: usageDatabase]).hasLocalCredentials()
        XCTAssertTrue(detected)
        let empty = await provider(data: [databasePath: "[]"]).hasLocalCredentials()
        XCTAssertFalse(empty)
        let absent = await provider().hasLocalCredentials()
        XCTAssertFalse(absent)
    }

    func testRefreshProducesTilesAndTrend() async {
        let snapshot = await provider(data: [databasePath: usageDatabase]).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.plan)
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.line(label: "Yesterday"))
        XCTAssertNotNil(snapshot.line(label: "Last 30 Days"))
        XCTAssertNotNil(snapshot.line(label: "Usage Trend"))
        XCTAssertNotNil(snapshot.usageHistory)
    }

    func testSpendTilesAreMarkedEstimated() async {
        let snapshot = await provider(data: [databasePath: usageDatabase]).refresh()
        guard case .values(_, let values, _, _, _, _)? = snapshot.line(label: "Today") else {
            return XCTFail("expected a Today tile")
        }
        // Tokens are measured; the dollars are priced locally from token counts, so they carry the ⓘ.
        XCTAssertTrue(values.contains(where: \.estimated))
        XCTAssertEqual(values.first?.number ?? 0, 0.001 + 0.002, accuracy: 1e-9)
    }

    func testRefreshErrorsWhenNoDatabaseFound() async {
        let snapshot = await provider().refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertNil(snapshot.line(label: "Today"))
    }

    func testRefreshErrorsWhenDatabaseUnreadable() async {
        let snapshot = await provider(
            data: [databasePath: usageDatabase],
            failing: [databasePath],
            databasePaths: [databasePath]
        ).refresh()
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertNil(snapshot.line(label: "Today"))
    }

    func testEmptyDatabaseShowsNoDataRatherThanAnError() async {
        let snapshot = await provider(data: [databasePath: "[]"]).refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.line(label: "Today"))
        XCTAssertEqual(snapshot.lines.count, 1)
        XCTAssertEqual(snapshot.lines.first?.label, MetricLine.noUsageData.label)
    }
}
