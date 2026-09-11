import Foundation

/// Typed failures for the Zcode provider, so telemetry groups them by a stable category
/// (see `ErrorCategory.swift`).
enum ZcodeUsageError: Error, LocalizedError, Equatable {
    /// No Zcode database on this machine — Zcode was never run here.
    case notInstalled
    /// Zcode databases exist but none could be read this refresh. Failing loudly here beats rendering
    /// authoritative-looking $0 tiles from an empty scan.
    case databaseUnreadable

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Zcode not detected. Use Zcode locally first so it records its own usage."
        case .databaseUnreadable:
            return "Couldn't read Zcode's local database. Quit Zcode and refresh, or check ~/.zcode's permissions."
        }
    }
}
