import Foundation

/// Tracks WorkBuddy's own local traffic: today/yesterday/30-day token + estimated-dollar tiles and a
/// usage trend, read straight from the session transcripts the WorkBuddy agent writes under
/// `~/.workbuddy/projects/`.
///
/// Entirely local — no credential, no network. WorkBuddy's own plan meters are out of scope here (the
/// app exposes no usage API), so this card answers one question: how much did this machine actually run
/// through WorkBuddy?
@MainActor
final class WorkBuddyProvider: ProviderRuntime {
    let provider = Provider(
        id: "workbuddy",
        displayName: "WorkBuddy",
        icon: .providerMark("workbuddy"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://www.codebuddy.cn/profile/usage")
        ]
    )

    let usageScanner: WorkBuddyUsageScanner
    let pricing: @Sendable () async -> ModelPricing
    let now: @Sendable () -> Date

    /// Names the local source on hover and flags the dollars as estimated: this machine only, priced
    /// from token counts at public API rates rather than billed by WorkBuddy's plan.
    private let sourceNote = "From your WorkBuddy logs (estimated)"

    init(
        usageScanner: WorkBuddyUsageScanner = WorkBuddyUsageScanner(),
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.usageScanner = usageScanner
        self.pricing = pricing
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: sourceNote
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // Same source as `refresh()`. Local-only, off the main actor.
        await loadOffMainActor { [usageScanner] in usageScanner.hasModelUsage() }
    }

    func refresh() async -> ProviderSnapshot {
        // One clock for the whole refresh, so the scan cutoff, tiles, trend, and snapshot timestamp
        // can't straddle a midnight boundary.
        let refreshedAt = now()
        let pricing = await pricing()

        let scan: LogUsageScan?
        do {
            scan = try await usageScanner.scan(now: refreshedAt, pricing: pricing)
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
        // No transcripts means WorkBuddy was never used here — an actionable error beats four "No data"
        // rows that don't explain why nothing is there. An *empty* transcript set is different: the tool
        // exists, so the tiles read "No data".
        guard let scan else {
            return ProviderSnapshot.error(provider: provider, error: WorkBuddyUsageError.notInstalled)
        }

        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            scan.series, to: &lines, now: refreshedAt,
            estimated: true,
            unknownModelsByDay: scan.unknownModelsByDay,
            modelUsage: scan.modelUsage,
            modelSourceNote: sourceNote,
            fallbackPricingModelsByDay: scan.fallbackPricingModelsByDay
        )
        SpendTileMapper.appendUsageTrend(scan.series, to: &lines, now: refreshedAt, note: sourceNote)
        MetricLine.appendNoDataIfNeeded(&lines)

        return ProviderSnapshot.make(
            provider: provider,
            plan: nil,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: ProviderUsageHistory(
                series: scan.series,
                modelUsage: scan.modelUsage,
                unknownModelsByDay: scan.unknownModelsByDay
            )
        )
    }
}
