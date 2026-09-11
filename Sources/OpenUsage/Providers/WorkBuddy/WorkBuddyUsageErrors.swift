import Foundation

/// Typed failures for the WorkBuddy provider, so telemetry groups them by a stable category
/// (see `ErrorCategory.swift`).
enum WorkBuddyUsageError: Error, LocalizedError, Equatable {
    /// No WorkBuddy session logs on this machine — WorkBuddy was never run here.
    case notInstalled
    /// Transcripts exist but none could be read this refresh. Failing loudly here beats rendering
    /// authoritative-looking $0 tiles from an empty scan.
    case logsUnreadable

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "WorkBuddy not detected. Run a WorkBuddy session first so it records its own usage."
        case .logsUnreadable:
            return "Couldn't read WorkBuddy's local session logs. Check the permissions on ~/.workbuddy."
        }
    }
}
