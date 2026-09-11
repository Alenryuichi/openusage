import CZstd
import Foundation

/// Streams decompressed lines out of DSH's `session.v3.jsonl.zstd` event logs.
///
/// Streaming rather than one-shot on purpose: a session log expands to tens of MB and a refresh re-reads
/// every log in the window, so the scanner never holds a whole transcript in memory. Records are handed
/// back one at a time and the caller parses what it needs (the scanner keeps only per-request usage rows,
/// not the conversation).
///
/// The vendored `CZstd` target is a read-only decoder — macOS ships no zstd at all — and the amalgamated
/// single file it wraps is documented in `Sources/CZstd/README.md`.
enum ZstdLineReader {
    enum Failure: Error, LocalizedError, Equatable {
        case unreadableFile(String)
        case corruptedFrame(String)

        var errorDescription: String? {
            switch self {
            case .unreadableFile(let path):
                return "Couldn't read DSH's session log at \(path)."
            case .corruptedFrame(let detail):
                return "A DSH session log is damaged (\(detail))."
            }
        }
    }

    /// Decompressed bytes per read. Large enough to keep syscall overhead irrelevant, small enough that a
    /// pathological frame can't balloon one allocation.
    private static let outputChunkBytes = 128 * 1024

    /// Read every decompressed line from `path`, calling `body` for each complete line (the trailing
    /// newline is stripped). Long lines are delivered whole across chunk boundaries. Returns `false` if
    /// `body` asked to stop, `true` when the file was read to the end.
    ///
    /// A torn trailing line (a log being appended to right now) is delivered as-is; the caller's JSON parse
    /// rejects it, which is the correct outcome for a partially written record.
    @discardableResult
    static func forEachLine(
        at path: String,
        _ body: (UnsafeRawBufferPointer) throws -> Bool
    ) throws -> Bool {
        guard let stream = FileHandle(forReadingAtPath: path) else {
            throw Failure.unreadableFile(path)
        }
        defer { try? stream.close() }

        guard let dstream = ZSTD_createDStream() else {
            throw Failure.corruptedFrame("could not allocate a decoder")
        }
        defer { ZSTD_freeDStream(dstream) }
        _ = ZSTD_initDStream(dstream)

        var pending = Data()
        let input = UnsafeMutablePointer<UInt8>.allocate(capacity: outputChunkBytes)
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: outputChunkBytes)
        defer {
            input.deallocate()
            output.deallocate()
        }
        var inputSize = 0

        // A `ZSTD_inBuffer` is a (pointer, size, position) triple; keeping one across calls lets a partial
        // input chunk resume exactly where the decoder stopped.
        var inBuffer = ZSTD_inBuffer(src: input, size: 0, pos: 0)

        while true {
            if inBuffer.pos >= inBuffer.size {
                let chunk = try stream.read(upToCount: outputChunkBytes) ?? Data()
                if chunk.isEmpty {
                    // Input exhausted. Flush whatever a final frame left pending, then stop.
                    guard try deliverPending(&pending, body) else { return false }
                    return true
                }
                chunk.copyBytes(to: input, count: chunk.count)
                inBuffer = ZSTD_inBuffer(src: input, size: chunk.count, pos: 0)
                inputSize += chunk.count
            }

            var outBuffer = ZSTD_outBuffer(dst: output, size: outputChunkBytes, pos: 0)
            let status = ZSTD_decompressStream(dstream, &outBuffer, &inBuffer)
            if ZSTD_isError(status) != 0 {
                throw Failure.corruptedFrame(String(cString: ZSTD_getErrorName(status)))
            }
            if outBuffer.pos > 0 {
                pending.append(output, count: outBuffer.pos)
                guard try deliverPending(&pending, body) else { return false }
            }
        }
    }

    /// Emit every complete line sitting in `pending`, leaving any partial tail behind. Returns `false`
    /// when the body asked to stop.
    private static func deliverPending(
        _ pending: inout Data,
        _ body: (UnsafeRawBufferPointer) throws -> Bool
    ) throws -> Bool {
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<newline]
            if line.isEmpty {
                pending.removeSubrange(pending.startIndex...newline)
                continue
            }
            let keepGoing = try line.withUnsafeBytes { try body($0) }
            pending.removeSubrange(pending.startIndex...newline)
            if !keepGoing { return false }
        }
        return true
    }
}
