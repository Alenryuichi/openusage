import Foundation

/// Where WorkBuddy keeps its local session logs on this machine. Resolution mirrors the other local
/// log providers: an explicit `WORKBUDDY_HOME` wins, then the default `~/.workbuddy`.
enum WorkBuddyPaths {
    /// WorkBuddy has no documented home override, so `WORKBUDDY_HOME` is honoured defensively — it
    /// costs one lookup and keeps a relocated home readable without a release (same as `ZCODE_HOME`).
    static let homeEnvironmentKey = "WORKBUDDY_HOME"
    static let defaultLeaf = ".workbuddy"
    /// One directory per workspace, one `*.jsonl` transcript per session.
    static let projectsLeaf = "projects"

    static func homeDirectory(environment: EnvironmentReading, homeDirectory: URL) -> String {
        if let override = environment.value(for: homeEnvironmentKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandHome(override).trimmingTrailingSlashes
        }
        return homeDirectory.appendingPathComponent(defaultLeaf).path
    }

    static func projectsDirectory(home: String) -> URL {
        URL(fileURLWithPath: expandHome(home.trimmingTrailingSlashes) + "/" + projectsLeaf, isDirectory: true)
    }

    /// Every `*.jsonl` transcript under `<home>/projects`, recursively, path-sorted so the scan order
    /// (and therefore the dedup that depends on it) is deterministic. A missing directory is the normal
    /// "never used WorkBuddy" case — `JSONLScanning.jsonlFiles` yields nothing for a directory it can't
    /// enumerate, so an unreadable tree is indistinguishable from an absent one here. That is acceptable
    /// for this provider: the probe in `WorkBuddyUsageScanner.hasModelUsage()` treats a present-but-
    /// unreadable home as a footprint, so `refresh()` still gets to run and report.
    static func logFiles(in home: String) -> [String] {
        JSONLScanning.jsonlFiles(under: projectsDirectory(home: home)).map(\.path)
    }
}
