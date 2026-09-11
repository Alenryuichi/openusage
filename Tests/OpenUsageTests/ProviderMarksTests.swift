import XCTest
@testable import OpenUsage

@MainActor
final class ProviderMarksTests: XCTestCase {
    /// Every provider in the registry must ship a vector mark. This is what catches a new provider that
    /// forgot its SVG, and it now covers the whole catalog instead of a hand-maintained list — the
    /// hand-maintained version silently stopped covering providers added after it was written.
    func testEveryRegisteredProviderLoadsAVectorMark() throws {
        let registry = WidgetRegistry.from(ProviderCatalog.make(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        XCTAssertFalse(registry.providers.isEmpty, "the registry should not be empty")

        for provider in registry.providers {
            let mark = try XCTUnwrap(
                ProviderMarks.mark(for: provider.icon.providerID),
                "\(provider.id) should load a vector mark for icon '\(provider.icon.providerID)'"
            )
            XCTAssertFalse(mark.path.isEmpty, "\(provider.id) mark must carry SVG path data")
            XCTAssertGreaterThan(mark.bounds.width, 0, "\(provider.id) mark must have a drawable width")
            XCTAssertGreaterThan(mark.bounds.height, 0, "\(provider.id) mark must have a drawable height")
        }
    }

    /// A mark may only use the path commands `SVGPath` implements. It silently stops parsing at an
    /// unsupported one, so an SVG with an arc (`A`) renders as a truncated — usually blank — mark with no
    /// error anywhere. Provider SVGs are copied from vendors, and arcs are common in real logos, so this
    /// is checked at the resource level rather than left to a visual review.
    func testEveryProviderMarkAvoidsUnsupportedPathCommands() throws {
        let supported: Set<Character> = ["M", "L", "H", "V", "C", "S", "Q", "T", "Z",
                                         "m", "l", "h", "v", "c", "s", "q", "t", "z"]
        for id in Self.bundledMarkIDs {
            let path = try XCTUnwrap(ProviderMarks.mark(for: id)?.path, "\(id) should load a vector mark")
            let commands = Set(path.filter(\.isLetter))
            let unsupported = commands.subtracting(supported)
            XCTAssertTrue(
                unsupported.isEmpty,
                "\(id).svg uses \(unsupported.sorted()) — SVGPath cannot parse those, so the mark renders truncated"
            )
        }
    }

    /// A provider that ships a mark should still have a *named* symbol behind it, so a mark that fails to
    /// load degrades to something recognisable rather than the generic dashed placeholder. `copilot`,
    /// `devin`, and `openusage` deliberately rely on the placeholder, so this is asserted for the
    /// providers that name one rather than for every bundled mark.
    func testProvidersWithNamedFallbacksDoNotUseThePlaceholder() {
        for id in ["antigravity", "claude", "codex", "cursor", "deepseek", "grok",
                   "ollama", "opencode", "openrouter", "workbuddy", "zai"] {
            XCTAssertNotEqual(
                ProviderMarks.symbolFallback(for: id), "app.dashed",
                "\(id) names a symbol fallback, so it must not resolve to the placeholder"
            )
        }
        // The placeholder is still what an unknown provider gets.
        XCTAssertEqual(ProviderMarks.symbolFallback(for: "not-a-provider"), "app.dashed")
    }

    /// One id per bundled `ProviderIcons/*.svg`, read from disk so a new file is covered automatically.
    private static var bundledMarkIDs: [String] {
        let url = Bundle.openUsageResources.url(forResource: "ProviderIcons", withExtension: nil)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url?.path ?? "")) ?? []
        return names.filter { $0.hasSuffix(".svg") }.map { String($0.dropLast(4)) }.sorted()
    }
}
