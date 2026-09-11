import Foundation

/// Tracks a DeepSeek account: the prepaid balance from DeepSeek's own API, plus the token spend DSH ran
/// through this machine.
///
/// The two halves come from different places on purpose. DeepSeek publishes no usage endpoint, so the
/// balance is the only account state its API can answer; the *usage* is measured from DSH's local session
/// logs, which record the provider's own per-request token counts. Each request is priced at DeepSeek's
/// peak or off-peak rate for the instant it was made (see `DeepSeekPricing`).
///
/// The key needs nothing from the user when DSH is set up here: `DeepSeekAuthStore` reads the credential
/// DSH already holds. Settings → API Keys can override it.
@MainActor
final class DeepSeekProvider: ProviderRuntime {
    let provider = Provider(
        id: "deepseek",
        displayName: "DeepSeek",
        icon: .providerMark("deepseek"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://platform.deepseek.com/usage"),
            ProviderLink(label: "API Keys", url: "https://platform.deepseek.com/api_keys")
        ]
    )

    let authStore: DeepSeekAuthStore
    let usageClient: DeepSeekUsageClient
    let usageScanner: DeepSeekUsageScanner
    let now: @Sendable () -> Date

    /// Names the local source on hover: this machine's DSH traffic, priced from token counts at DeepSeek's
    /// public rates rather than read from an invoice.
    private let sourceNote = "From your DSH session logs (estimated)"

    init(
        authStore: DeepSeekAuthStore = DeepSeekAuthStore(),
        usageClient: DeepSeekUsageClient = DeepSeekUsageClient(),
        usageScanner: DeepSeekUsageScanner = DeepSeekUsageScanner(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.usageScanner = usageScanner
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            // The balance is exported as a program-facing scalar (the shape OpenRouter's balance uses).
            // `usd` is the unit the app's value formatter speaks; a CNY-denominated account still renders
            // correctly on the card, with its mark carried as the value's unit label.
            .values(id: "deepseek.balance", provider: provider, title: "Total Balance",
                    metricLabel: "Total Balance", selection: .all, valueWord: "left")
                .exportingLimit("balance", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .values(id: "deepseek.breakdown", provider: provider, title: "Balance Breakdown",
                    metricLabel: "Balance Breakdown", selection: .all),
            // Local DSH traffic: tokens measured per request, dollars imputed at DeepSeek's own rates.
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: sourceNote
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Same sources as `refresh()`: the stored or discovered API key, or DSH usage already on this
        // machine. Local-only, off the main actor.
        await loadOffMainActor { [authStore, usageScanner] in
            authStore.loadAPIKey() != nil || usageScanner.hasSessionUsage()
        }
    }

    func refresh() async -> ProviderSnapshot {
        // One clock for the whole refresh, so the scan cutoff, tiles, trend, and snapshot timestamp can't
        // straddle a midnight boundary.
        let refreshedAt = now()

        var lines: [MetricLine] = []
        var plan: String?
        var balanceFailure: Error?

        // The balance is best-effort: a rejected or unreachable key must not blank out the local usage
        // rows, which need no network at all.
        if let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }) {
            switch await fetchBalance(apiKey: auth.apiKey) {
            case .success(let payload):
                lines += DeepSeekUsageMapper.lines(for: payload.balances[0])
                // Whether the wallet still covers calls is the one piece of account state this key can
                // read, so it rides the header as the plan name.
                plan = payload.isAvailable.map { $0 ? "Active" : "Balance exhausted" }
            case .failed(let error):
                balanceFailure = error
            }
        } else {
            balanceFailure = DeepSeekAuthError.missingKey
        }

        // Local usage, measured from DSH's own session logs.
        let scan: LogUsageScan?
        do {
            scan = try await usageScanner.scan(now: refreshedAt)
        } catch {
            if lines.isEmpty {
                return ProviderSnapshot.error(provider: provider, error: error)
            }
            AppLog.warn(
                LogTag.plugin("deepseek"),
                "DSH session logs unreadable; showing balance only: \(error.localizedDescription)"
            )
            scan = nil
        }

        if let scan {
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &lines, now: refreshedAt,
                estimated: true,
                unknownModelsByDay: scan.unknownModelsByDay,
                modelUsage: scan.modelUsage,
                modelSourceNote: sourceNote,
                fallbackPricingModelsByDay: scan.fallbackPricingModelsByDay
            )
            SpendTileMapper.appendUsageTrend(scan.series, to: &lines, now: refreshedAt, note: sourceNote)
        }

        // Nothing at all came back. A failed balance call is the more actionable failure — it means the key
        // is missing, rejected, or the network is down — so it wins over the absence of local logs.
        if lines.isEmpty {
            if let balanceFailure { return ProviderSnapshot.error(provider: provider, error: balanceFailure) }
            return ProviderSnapshot.error(provider: provider, error: DeepSeekUsageError.logsUnreadable)
        }
        MetricLine.appendNoDataIfNeeded(&lines)

        return ProviderSnapshot.make(
            provider: provider,
            plan: plan,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: scan.map {
                ProviderUsageHistory(
                    series: $0.series,
                    modelUsage: $0.modelUsage,
                    unknownModelsByDay: $0.unknownModelsByDay
                )
            }
        )
    }

    private enum BalanceFetch {
        case success((balances: [DeepSeekUsageMapper.Balance], isAvailable: Bool?))
        case failed(DeepSeekUsageError)
    }

    private func fetchBalance(apiKey: String) async -> BalanceFetch {
        let response: HTTPResponse
        do {
            response = try await usageClient.fetchBalance(apiKey: apiKey)
        } catch {
            return .failed(.connectionFailed)
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            // The key itself was rejected, so the message must point at the key rather than the network.
            return .failed(.invalidKey)
        }
        guard (200..<300).contains(response.statusCode) else {
            return .failed(.requestFailed(response.statusCode))
        }
        guard let payload = DeepSeekUsageMapper.balances(from: response.body) else {
            // A 2xx whose body carries no parsable balance is a provider-side surprise, not "no data".
            return .failed(.noBalance)
        }
        return .success(payload)
    }
}

extension DeepSeekProvider: APIKeyManaging {
    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { authStore.currentAPIKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveAPIKey(key) }
    func deleteAPIKey() throws { try authStore.deleteAPIKey() }
}
