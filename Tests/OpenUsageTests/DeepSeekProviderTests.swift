import XCTest
@testable import OpenUsage

// MARK: - DeepSeekAuthStoreTests

final class DeepSeekAuthStoreTests: XCTestCase {
    func testReadsTheEnvironmentKey() {
        let store = DeepSeekAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["DEEPSEEK_API_KEY": "sk-env"])
        )
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-env")
    }

    func testReadsJSONAndTrimmedPlainTextConfigFiles() {
        let cases = [
            (DeepSeekAuthStore.configPaths[0], #"{"apiKey":"sk-json"}"#, "sk-json"),
            (DeepSeekAuthStore.configPaths[1], "  sk-plain\n", "sk-plain")
        ]

        for (path, content, expected) in cases {
            let store = DeepSeekAuthStore(files: FakeFiles([path: content]), environment: FakeEnvironment())
            XCTAssertEqual(store.loadAPIKey()?.apiKey, expected, path)
        }
    }

    func testReturnsNilWhenNoKeyAnywhere() {
        let store = DeepSeekAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNil(store.loadAPIKey())
        XCTAssertEqual(store.keyStatus(), .notSet)
    }

    func testSaveWritesTheOpenUsageConfigFileAndOverridesTheEnvironment() throws {
        let files = FakeFiles()
        let store = DeepSeekAuthStore(files: files, environment: FakeEnvironment(["DEEPSEEK_API_KEY": "sk-env"]))

        try store.saveAPIKey("  sk-saved  ")

        XCTAssertEqual(files.files[DeepSeekAuthStore.configPaths[0]], #"{"apiKey":"sk-saved"}"#)
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-saved")
        XCTAssertEqual(store.keyStatus(), .overrideActive)
    }

    func testSaveRejectsAnEmptyKeyAndDeleteClearsEveryPath() throws {
        let files = FakeFiles([
            DeepSeekAuthStore.configPaths[0]: #"{"apiKey":"sk-a"}"#,
            DeepSeekAuthStore.configPaths[1]: #"{"apiKey":"sk-b"}"#
        ])
        let store = DeepSeekAuthStore(files: files, environment: FakeEnvironment())

        XCTAssertThrowsError(try store.saveAPIKey("   ")) { error in
            XCTAssertEqual(error as? DeepSeekAuthError, .missingKey)
        }

        try store.deleteAPIKey()
        XCTAssertNil(store.loadAPIKey())
    }
}

// MARK: - DeepSeekUsageMapperTests

final class DeepSeekUsageMapperTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testParsesACNYBalanceWithGrantedAndToppedUpCredit() throws {
        let payload = try XCTUnwrap(DeepSeekUsageMapper.balances(from: data(#"""
        {"is_available":true,"balance_infos":[
          {"currency":"CNY","total_balance":"70.65","granted_balance":"20.65","topped_up_balance":"50.00"}
        ]}
        """#)))

        XCTAssertEqual(payload.isAvailable, true)
        let balance = try XCTUnwrap(payload.balances.first)
        XCTAssertEqual(balance.currency, "CNY")
        XCTAssertEqual(balance.symbol, "¥")
        XCTAssertEqual(balance.total, 70.65)
        XCTAssertEqual(balance.granted, 20.65)
        XCTAssertEqual(balance.toppedUp, 50.0)
    }

    func testUSDTotalBalanceCarriesTheDollarKind() throws {
        let payload = try XCTUnwrap(DeepSeekUsageMapper.balances(from: data(#"""
        {"is_available":true,"balance_infos":[
          {"currency":"USD","total_balance":"12.34","granted_balance":"0.00","topped_up_balance":"12.34"}
        ]}
        """#)))

        let lines = DeepSeekUsageMapper.lines(for: payload.balances[0])
        XCTAssertEqual(lines.map(\.label), ["Total Balance", "Balance Breakdown"])

        guard case .values(_, let values, _, _, _, _) = lines[0] else { return XCTFail("expected a values row") }
        XCTAssertEqual(values.map(\.kind), [.dollars])
        XCTAssertEqual(values[0].number, 12.34, accuracy: 1e-9)
        XCTAssertEqual(MetricFormatter.string(for: values[0], style: .row), "$12.34")
        // USD keeps the app's bare dollar rendering: no unit label.
        XCTAssertNil(values[0].label)
    }

    /// The shape most accounts are in, and the one the default layout exposes: a topped-up-only balance
    /// (no granted credit yet). The split must still carry both halves — a skipped line renders as
    /// "No data" on a tile that is on by default, which reads as broken rather than as "no granted
    /// credit". Regression: this row used to be omitted unless *both* halves were positive.
    func testToppedUpOnlyBalanceStillReportsBothHalves() throws {
        let payload = try XCTUnwrap(DeepSeekUsageMapper.balances(from: data(#"""
        {"is_available":true,"balance_infos":[
          {"currency":"CNY","total_balance":"63.58","granted_balance":"0.00","topped_up_balance":"63.58"}
        ]}
        """#)))

        let lines = DeepSeekUsageMapper.lines(for: payload.balances[0])
        XCTAssertEqual(lines.map(\.label), ["Total Balance", "Balance Breakdown"])

        guard case .values(_, let split, _, _, _, _) = lines[1] else { return XCTFail("expected a values row") }
        XCTAssertEqual(split.map(\.number), [0, 63.58])
        // The yuan mark carries the currency, so no unit word is needed on either half.
        XCTAssertEqual(split.map(\.label), [nil, nil])
        XCTAssertEqual(MetricFormatter.string(for: split[0], style: .row), "¥0.00")
        XCTAssertEqual(MetricFormatter.string(for: split[1], style: .row), "¥63.58")
    }

    func testGrantedOnlyBalanceStillReportsBothHalves() throws {
        let payload = try XCTUnwrap(DeepSeekUsageMapper.balances(from: data(#"""
        {"is_available":true,"balance_infos":[
          {"currency":"USD","total_balance":"5.00","granted_balance":"5.00","topped_up_balance":"0.00"}
        ]}
        """#)))

        let lines = DeepSeekUsageMapper.lines(for: payload.balances[0])
        guard case .values(_, let split, _, _, _, _) = lines[1] else { return XCTFail("expected a values row") }
        XCTAssertEqual(split.map(\.number), [5.0, 0])
    }

    func testNonUSDCurrencyKeepsCentsWithoutReadingAsDollars() throws {
        let payload = try XCTUnwrap(DeepSeekUsageMapper.balances(from: data(#"""
        {"is_available":true,"balance_infos":[
          {"currency":"CNY","total_balance":"70.65","granted_balance":"20.65","topped_up_balance":"50.00"}
        ]}
        """#)))

        let lines = DeepSeekUsageMapper.lines(for: payload.balances[0])
        XCTAssertEqual(lines.map(\.label), ["Total Balance", "Balance Breakdown"])

        guard case .values(_, let total, _, _, _, _) = lines[0],
              case .values(_, let split, _, _, _, _) = lines[1]
        else { return XCTFail("expected two values rows") }

        // Full cents, with the yuan mark standing in for the dollar sign.
        XCTAssertEqual(MetricFormatter.string(for: total[0], style: .row), "¥70.65")
        XCTAssertEqual(split.map(\.number), [20.65, 50.0])
        XCTAssertEqual(MetricFormatter.string(for: split[0], style: .row), "¥20.65")
        XCTAssertEqual(total[0].currencySymbol, "¥")
    }

    func testBalanceExhaustedReadsFalse() throws {
        let payload = try XCTUnwrap(DeepSeekUsageMapper.balances(from: data(#"""
        {"is_available":false,"balance_infos":[
          {"currency":"USD","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"}
        ]}
        """#)))
        XCTAssertEqual(payload.isAvailable, false)
    }

    func testUnparsableOrEmptyPayloadsReturnNil() {
        XCTAssertNil(DeepSeekUsageMapper.balances(from: data("not json")))
        XCTAssertNil(DeepSeekUsageMapper.balances(from: data(#"{"is_available":true}"#)))
        XCTAssertNil(DeepSeekUsageMapper.balances(from: data(#"{"balance_infos":[]}"#)))
        // A currency entry with no amount is dropped at the boundary rather than priced at zero.
        XCTAssertNil(DeepSeekUsageMapper.balances(from: data(#"{"balance_infos":[{"currency":"USD"}]}"#)))
    }
}

// MARK: - DeepSeekProviderTests

@MainActor
final class DeepSeekProviderTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    /// A provider wired to a fake HTTP client, a fixed clock, and an injected session-log list — so a test
    /// never reads the real `~/.dsh` of the machine running it.
    private func provider(
        key: String? = "sk-test",
        response: HTTPResponse,
        sessionLogs: [String] = []
    ) -> (DeepSeekProvider, FakeHTTPClient) {
        let http = FakeHTTPClient(response: response)
        let now = self.now
        let store = DeepSeekAuthStore(
            files: FakeFiles(key.map { [DeepSeekAuthStore.configPaths[0]: #"{"apiKey":"\#($0)"}"#] } ?? [:]),
            environment: FakeEnvironment()
        )
        let provider = DeepSeekProvider(
            authStore: store,
            usageClient: DeepSeekUsageClient(http: http),
            usageScanner: DeepSeekUsageScanner(
                environment: FakeEnvironment(["DSH_HOME": "/tmp/dsh-fixture"]),
                homeDirectory: { URL(fileURLWithPath: "/tmp/dsh-fixture") },
                sessionLogFiles: { _ in sessionLogs }
            ),
            now: { now }
        )
        return (provider, http)
    }

    private func ok(_ json: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
    }

    func testRefreshMapsTheBalanceRowsAndSendsABearerToken() async throws {
        let (provider, http) = provider(response: ok(#"""
        {"is_available":true,"balance_infos":[
          {"currency":"CNY","total_balance":"70.65","granted_balance":"20.65","topped_up_balance":"50.00"}
        ]}
        """#))

        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Active")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Total Balance", "Balance Breakdown"])

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://api.deepseek.com/user/balance")
        XCTAssertEqual(request.headers["Authorization"], "Bearer sk-test")
    }

    func testExhaustedBalanceRidesTheHeader() async {
        let (provider, _) = provider(response: ok(#"""
        {"is_available":false,"balance_infos":[
          {"currency":"USD","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"}
        ]}
        """#))

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Balance exhausted")
    }

    func testMissingKeyIsNotLoggedInAndNeverCallsTheAPI() async {
        let (provider, http) = provider(key: nil, response: ok("{}"))

        let detected = await provider.hasLocalCredentials()
        XCTAssertFalse(detected)
        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testRejectedKeyIsAuthInvalidAndAServerErrorIsHTTP5xx() async {
        let (unauthorized, _) = provider(response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
        let unauthorizedCategory = await unauthorized.refresh().errorCategory

        XCTAssertEqual(unauthorizedCategory, .authInvalid)

        let (serverError, _) = provider(response: HTTPResponse(statusCode: 503, headers: [:], body: Data()))
        let serverErrorCategory = await serverError.refresh().errorCategory

        XCTAssertEqual(serverErrorCategory, .http5xx)
    }

    func testTransportFailureIsNetwork() async {
        let now = self.now
        let store = DeepSeekAuthStore(
            files: FakeFiles([DeepSeekAuthStore.configPaths[0]: #"{"apiKey":"sk-test"}"#]),
            environment: FakeEnvironment()
        )
        let provider = DeepSeekProvider(
            authStore: store,
            usageClient: DeepSeekUsageClient(http: FailingHTTPClient()),
            // No session logs, so the balance failure is the only thing to report.
            usageScanner: DeepSeekUsageScanner(
                environment: FakeEnvironment(["DSH_HOME": "/tmp/dsh-fixture"]),
                homeDirectory: { URL(fileURLWithPath: "/tmp/dsh-fixture") },
                sessionLogFiles: { _ in [] }
            ),
            now: { now }
        )

        let providerCategory = await provider.refresh().errorCategory
        XCTAssertEqual(providerCategory, .network)
    }

    func testSuccessfulResponseWithoutABalanceFailsLoudly() async {
        let (provider, _) = provider(response: ok(#"{"is_available":true,"balance_infos":[]}"#))

        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .decoding)
    }

    func testProviderIsAPIKeyManageable() {
        let (provider, _) = provider(response: ok("{}"))

        XCTAssertEqual(provider.apiKeyStatus, .saved)
        XCTAssertEqual(provider.currentAPIKey(), "sk-test")
        XCTAssertEqual(provider.provider.id, "deepseek")
    }

    /// The rendered popover text, resolved from a real provider snapshot through the same store the UI
    /// reads — so the currency handling is verified where the user actually sees it, not only in the mapper.
    func testCardRendersTheBalanceWithItsOwnCurrencyMark() async {
        let provider = DeepSeekProvider()
        let descriptors = provider.widgetDescriptors
        let payload = DeepSeekUsageMapper.balances(from: Data(#"""
        {"is_available":true,"balance_infos":[
          {"currency":"CNY","total_balance":"70.65","granted_balance":"20.65","topped_up_balance":"50.00"}
        ]}
        """#.utf8))!
        let runtime = TestProviderRuntime(
            provider: provider.provider,
            descriptors: descriptors,
            snapshot: ProviderSnapshot(
                providerID: "deepseek",
                displayName: "DeepSeek",
                lines: DeepSeekUsageMapper.lines(for: payload.balances[0])
            )
        )
        let suiteName = "OpenUsageTests.deepseek-render.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider.provider], descriptors: descriptors),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        let balance = store.data(for: descriptors[0])
        XCTAssertEqual(balance.unboundedDetail, "¥70.65 left")
        XCTAssertEqual(balance.menuBarValue, "¥71")

        let breakdown = store.data(for: descriptors[1])
        XCTAssertEqual(breakdown.unboundedDetail, "¥20.65 · ¥50.00")
    }
}

/// An HTTP client that never completes a request, for the transport-failure path.
private struct FailingHTTPClient: HTTPClient {
    struct Offline: Error {}

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw Offline()
    }
}
