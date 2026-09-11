import Foundation

struct DeepSeekAuth: Hashable, Sendable {
    var apiKey: String
}

enum DeepSeekAuthError: Error, LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case saveFailed
    case deleteFailed

    init(_ failure: UserAPIKeyStore.Failure) {
        switch failure {
        case .missingKey: self = .missingKey
        case .saveFailed: self = .saveFailed
        case .deleteFailed: self = .deleteFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No DeepSeek API key. Set DEEPSEEK_API_KEY or add it to ~/.config/openusage/deepseek.json."
        case .invalidKey:
            return "DeepSeek API key rejected. Check your key at platform.deepseek.com/api_keys."
        case .saveFailed:
            return "Couldn't save the DeepSeek API key."
        case .deleteFailed:
            return "Couldn't remove the saved DeepSeek API key."
        }
    }
}

/// Reads a [DeepSeek](https://platform.deepseek.com) API key already on the machine.
///
/// DeepSeek ships no companion CLI of its own that stashes a credential, but the clients that talk to its
/// API do — and the one people actually run here is DSH (DeepSeek Harness), which writes the key a user
/// exported for it into `~/.dsh/.credentials.yaml`. So the explicit user path wins, then a discovered
/// DSH login is used, then the environment:
///
/// 1. `~/.config/openusage/deepseek.json` / `~/.config/deepseek/key.json` — the explicit path, which a
///    user edits to rotate the key and which therefore must be able to override anything discovered.
/// 2. `~/.dsh/.credentials.yaml` — DSH's own credential, read strictly (see `reference(inCredentials:)`).
///    Needs nothing from the user because DSH is already logged in on this machine.
/// 3. `DEEPSEEK_API_KEY` in the environment.
///
/// A GUI app launched from Finder/Dock doesn't inherit the interactive shell environment, so
/// `ProcessEnvironmentReader` captures the login shell's environment at launch (see
/// `LoginShellEnvironment`) — meaning an env var exported in a shell profile is honored even in a
/// packaged build.
struct DeepSeekAuthStore: Sendable {
    /// Config files checked in order; first readable key wins. JSON (`apiKey` / `api_key` / `key`) or a
    /// plain-text file containing only the key.
    static let configPaths = [
        "~/.config/openusage/deepseek.json",
        "~/.config/deepseek/key.json"
    ]
    static let environmentNames = ["DEEPSEEK_API_KEY"]
    /// The reference name DSH stores the key under.
    static let dshReferenceName = "DEEPSEEK_API_KEY"

    private let store: UserAPIKeyStore
    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let files: TextFileAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.store = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { DeepSeekAuthError($0) }
        )
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.files = files
    }

    /// The key to authenticate with: the explicit config file (or the environment) first, then a
    /// credential discovered in DSH's own store.
    func loadAPIKey() -> DeepSeekAuth? {
        if let key = store.loadKey() { return DeepSeekAuth(apiKey: key) }
        return dshAPIKey().map(DeepSeekAuth.init(apiKey:))
    }

    /// The `refs.DEEPSEEK_API_KEY` entry DSH keeps in its credentials file, if DSH is set up here.
    func dshAPIKey() -> String? {
        let home = DeepSeekPaths.homeDirectory(environment: environment, homeDirectory: homeDirectory())
        let path = DeepSeekPaths.credentialsFile(home: home)
        guard files.exists(path), let text = try? files.readText(path) else { return nil }
        return Self.reference(inCredentials: text, named: Self.dshReferenceName)
    }

    /// Pull one `NAME: value` entry out of the top-level `refs` block of a DSH credentials file.
    ///
    /// Deliberately strict, and deliberately not `UserAPIKeyStore`'s generic reader: this file also holds
    /// unrelated secrets (a browser-session grant under `records`), and the generic reader's plain-text
    /// fallback would return the whole document — handing a *different* secret to the API as if it were
    /// the key. Only a value under `refs` is accepted, and the scan stops at the next top-level key so a
    /// same-named entry nested elsewhere can never be mistaken for it.
    static func reference(inCredentials text: String, named name: String) -> String? {
        var inRefs = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            let isTopLevel = !(rawLine.first.map { $0 == " " || $0 == "\t" } ?? true)
            if isTopLevel {
                // `refs:` opens the block; any other top-level key closes it.
                inRefs = line == "refs:"
                continue
            }
            guard inRefs, let colon = line.firstIndex(of: ":") else { continue }

            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            guard key == name else { continue }
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.nilIfEmpty
        }
        return nil
    }

    func currentAPIKey() -> String? { loadAPIKey()?.apiKey }

    /// Which sources currently hold a key — drives the four-state per-provider API-key editor.
    ///
    /// A key discovered in DSH's credentials reads as `fromEnvironment`: it belongs to another tool rather
    /// than to OpenUsage, and saving one here is what turns it into an `overrideActive` key. A key in the
    /// environment behaves the same way, so the generic store's `fromEnvironment`/`overrideActive`
    /// verdicts already cover it.
    func keyStatus() -> APIKeyStatus {
        switch store.keyStatus() {
        case .saved:
            // A config file plus any other source is an override, and a discovered DSH credential is
            // another source even though it isn't an exported variable.
            return dshAPIKey() != nil ? .overrideActive : .saved
        case .notSet:
            return dshAPIKey() != nil ? .fromEnvironment : .notSet
        case .fromEnvironment, .overrideActive:
            return store.keyStatus()
        }
    }

    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }
}
