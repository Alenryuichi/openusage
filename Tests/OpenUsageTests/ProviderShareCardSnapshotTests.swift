import XCTest
@testable import OpenUsage

/// Renders provider cards through the app's own share-card path and writes PNGs, so a visual change can
/// be reviewed without a screen recording of the popover (the panel is a borderless `NSPanel` behind the
/// menu bar, and capturing it needs Accessibility permission to click the status item).
///
/// Set `OPENUSAGE_SNAPSHOT_DIR` to a writable directory to emit the images; without it the test only
/// proves the cards rasterize, so ordinary `swift test` runs leave nothing behind.
@MainActor
final class ProviderShareCardSnapshotTests: XCTestCase {
    private func card(providerID: String, displayName: String, plan: String?, rows: [(String, [MetricValue])]) -> ShareCardView {
        let provider = Provider(id: providerID, displayName: displayName, icon: .providerMark(providerID))
        let widgets = rows.map { title, values in
            var data = WidgetData(title: title, icon: provider.icon, kind: .dollars, used: 0, limit: nil)
            data.values = values
            data.selection = .all
            data.hasData = true
            return data
        }
        return ShareCardView(provider: provider, plan: plan, rows: widgets, appearance: .light)
    }

    func testProviderCardsRasterize() throws {
        let deepseek = card(providerID: "deepseek", displayName: "DeepSeek", plan: "Active", rows: [
            ("Total Balance", [MetricValue(number: 53.57, kind: .dollars, label: nil, currencySymbol: "¥")]),
            ("Balance Breakdown", [
                MetricValue(number: 0, kind: .dollars, label: nil, currencySymbol: "¥"),
                MetricValue(number: 53.57, kind: .dollars, label: nil, currencySymbol: "¥")
            ]),
            ("Today", [MetricValue(number: 4.10, kind: .dollars, estimated: true),
                       MetricValue(number: 588_800_000, kind: .count, label: "tokens")]),
            ("Yesterday", [MetricValue(number: 2.84, kind: .dollars, estimated: true),
                           MetricValue(number: 540_100_000, kind: .count, label: "tokens")]),
            ("Last 30 Days", [MetricValue(number: 6.93, kind: .dollars, estimated: true),
                              MetricValue(number: 1_100_000_000, kind: .count, label: "tokens")])
        ])
        let workbuddy = card(providerID: "workbuddy", displayName: "WorkBuddy", plan: nil, rows: [
            ("Yesterday", [MetricValue(number: 21.00, kind: .dollars, estimated: true),
                           MetricValue(number: 267_600_000, kind: .count, label: "tokens")]),
            ("Last 30 Days", [MetricValue(number: 38.90, kind: .dollars, estimated: true),
                              MetricValue(number: 438_000_000, kind: .count, label: "tokens")])
        ])

        let cards: [(String, ShareCardView)] = [("deepseek", deepseek), ("workbuddy", workbuddy)]
        for (name, view) in cards {
            let image = try XCTUnwrap(ShareCardRenderer.image(for: view), name)
            let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image), name)
            let rep = try XCTUnwrap(image.representations.first)
            guard let dir = ProcessInfo.processInfo.environment["OPENUSAGE_SNAPSHOT_DIR"] else {
                print("RENDER \(name): \(rep.pixelsWide)x\(rep.pixelsHigh) (\(png.count) bytes; set OPENUSAGE_SNAPSHOT_DIR to write)")
                continue
            }
            let url = URL(fileURLWithPath: dir).appendingPathComponent("openusage-card-\(name).png")
            try png.write(to: url)
            print("RENDER \(name): \(rep.pixelsWide)x\(rep.pixelsHigh) -> \(url.path) (\(png.count) bytes)")
        }
    }
}
