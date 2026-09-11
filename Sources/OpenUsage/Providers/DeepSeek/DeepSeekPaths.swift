import Foundation

/// Where DeepSeek-related state lives on this machine.
///
/// DeepSeek has no usage API, so the only *measured* usage numbers available locally are the ones
/// written by a client that talks to the API. DSH (DeepSeek Harness) is such a client, and it keeps
/// both a credential and a per-session usage summary on disk — this type names those locations so the
/// auth store and the usage scanner agree on them.
enum DeepSeekPaths {
    /// DSH's home: an explicit `DSH_HOME` override, then the default `~/.dsh`.
    static let homeEnvironmentKey = "DSH_HOME"
    static let defaultHomeLeaf = ".dsh"

    static func homeDirectory(environment: EnvironmentReading, homeDirectory: URL) -> String {
        if let override = environment.value(for: homeEnvironmentKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return expandHome(override).trimmingTrailingSlashes
        }
        return homeDirectory.appendingPathComponent(defaultHomeLeaf).path
    }

    /// DSH's credential file. `refs` there is a flat `NAME: value` map, which is where the DeepSeek API
    /// key a user exported for DSH ends up.
    static func credentialsFile(home: String) -> String {
        expandHome(home.trimmingTrailingSlashes) + "/.credentials.yaml"
    }

    /// DSH's session event logs: `<home>/sessions/<escaped-cwd>/session-<uuid>/session.v3.jsonl.zstd`.
    ///
    /// The layout is two levels deep with two different naming schemes for the directory components (the
    /// project directory is the escaped cwd, the session directory is `session-<uuid>` or a bare uuid), so
    /// the tree is enumerated and every `session*.jsonl.zstd` file is taken — a future rename of the
    /// project-directory scheme then costs nothing. Path-sorted for deterministic iteration.
    static func sessionLogFiles(home: String) -> [String] {
        let root = expandHome(home.trimmingTrailingSlashes) + "/sessions"
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys, options: []
        ) else { return [] }

        var files: [String] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasSuffix(".jsonl.zstd"),
                  (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true
            else { continue }
            files.append(url.path)
        }
        return files.sorted()
    }
}
