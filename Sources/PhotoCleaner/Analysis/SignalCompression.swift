import Compression
import Foundation
import SQLite3
import Vision

/// zlib compression for the blobs stored in `asset_signals.payload`.
///
/// ## Why compress at all
///
/// A FeaturePrint is 768 floats — 3,072 B raw, 4,351 B as JSON. For 53,177 assets
/// that is 231 MB of cache against an otherwise-15 MB cache. zlib brings the
/// JSON to ~2.7 KB each, about 144 MB: still the largest thing in the cache, but
/// roughly a third of the size, for a few lines of code and a decode cost of
/// microseconds.
///
/// ## Why JSON and not the raw bytes
///
/// `FeaturePrintObservation` cannot be rebuilt from its raw payload through any
/// public API — the only initialiser takes another observation. Its `Codable`
/// conformance is the only route in, and it was verified bit-exact: worst
/// distance error `0.0` across 400 measured pairs. So the bytes are JSON, and
/// these are the only two places that know it.
///
/// A one-byte prefix records the codec. It earns its keep for the *older* format:
/// a payload with no marker is read as plain JSON, which is what a build from
/// before compression wrote. A payload written by some future codec is a different
/// case and is not covered by this branch — such a change is expected to come with
/// an `analyzerVersion` bump, and `CacheStore.refreshFeaturePrintQueue` re-queues
/// every vector written under an older version, so the two mechanisms agree rather
/// than overlapping.
enum SignalCompression: Sendable {
    /// `zlib` streaming format, not raw deflate, so the stored bytes carry their
    /// own checksum: a truncated payload fails to decompress instead of decoding
    /// into plausible-looking nonsense.
    private static let algorithm = COMPRESSION_ZLIB
    private static let marker: UInt8 = 1
    /// The JSON of a FeaturePrint is 4,351 B. This only bounds a corrupt length
    /// prefix; normal payloads are far below it.
    private static let maximumDecompressedSize = 1 << 20

    /// `nil` for input that cannot usefully be stored — an empty payload, or one
    /// the output buffer could not hold.
    ///
    /// Empty in, `nil` out rather than the empty `Data` back: a zero-length blob
    /// reads back as *no* value at all (`read` cannot see one), which would leave a
    /// signal row that looks written and never is — and, because the row exists, the
    /// backfill queue would never re-queue it. Storing nothing is the answer that
    /// leaves the asset eligible.
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 1024
        var out = Data(count: capacity + 1)
        let written = out.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source in
                guard let base = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(base + 1, capacity,
                                                 sourceBase, data.count,
                                                 nil, algorithm)
            }
        }
        // 0 means the buffer was too small; a negative value is an encoding error.
        guard written > 0 else { return nil }
        out[0] = marker
        out.removeLast(capacity - written)
        return out
    }

    /// Decompresses a payload, tolerating an unmarked one written before
    /// compression existed.
    ///
    /// `nil` for anything that does not inflate — which is the point of the zlib
    /// container: a truncated or corrupt payload fails here instead of decoding
    /// into plausible-looking nonsense. Callers skip a row that will not decode
    /// rather than failing the whole read, so one damaged vector costs one photo its
    /// place in a group instead of costing the library every group.
    static func decompress(_ data: Data) -> Data? {
        guard let first = data.first else { return nil }
        guard first == marker else { return data }
        let body = data.dropFirst()
        var out = Data(count: maximumDecompressedSize)
        let written = out.withUnsafeMutableBytes { destination -> Int in
            body.withUnsafeBytes { source in
                guard let base = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(base, maximumDecompressedSize,
                                                 sourceBase, body.count,
                                                 nil, algorithm)
            }
        }
        guard written > 0 else { return nil }
        out.removeLast(maximumDecompressedSize - written)
        return out
    }

    static func featurePrint(from data: Data) -> FeaturePrintObservation? {
        guard let decoded = decompress(data) else { return nil }
        return try? JSONDecoder().decode(FeaturePrintObservation.self, from: decoded)
    }

    static func featurePrintData(_ observation: FeaturePrintObservation) -> Data? {
        try? JSONEncoder().encode(observation)
    }

    static func faceCaptureResult(from data: Data) -> FaceCaptureResult? {
        guard let decoded = decompress(data) else { return nil }
        return try? JSONDecoder().decode(FaceCaptureResult.self, from: decoded)
    }

    static func faceCaptureResultData(_ result: FaceCaptureResult) -> Data? {
        try? JSONEncoder().encode(result)
    }

    /// Reads a blob column. `SQLITE_TRANSIENT` is `SQLite`'s spelling of "copy
    /// this, the pointer dies when I return" — the raw column pointer is only
    /// valid until the next step, so it must be copied out.
    static func bind(_ statement: OpaquePointer, _ index: Int32, _ data: Data) {
        _ = data.withUnsafeBytes { raw in
            sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(raw.count), transient)
        }
    }

    /// Copies a blob column out, or `nil` when the column holds no value.
    ///
    /// A zero-length blob and SQL NULL are both `nil` here: `sqlite3_column_blob`
    /// cannot tell them apart, and neither is a payload anything can decode, so the
    /// caller treats both as "this signal is not stored" — which is what
    /// `refreshFeaturePrintQueue` and the face queue both mean by absence.
    static func read(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return nil }
        return Data(bytes: pointer, count: count)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
