import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import os
import Photos

/// Video-specific PhotoKit and AVFoundation work, in one file.
///
/// Two reasons this exists rather than as three more methods on `PhotoLibrary`:
///
/// - `PhotoLibrary` is the image path, and `AVFoundation` in it would put an
///   entire video framework — a large, thread-pool-heavy one — behind every
///   thumbnail request. The contract is that `import AVFoundation` appears
///   exactly here, and the only way to keep that true is to have nowhere else it
///   would plausibly be wanted.
/// - Every question about a `PHAssetResource` — which resource is the clip, what
///   extension Photos gives it, whether it is on this Mac — now has one home.
///   Those questions are the ones that are answered wrongly in three slightly
///   different ways when there are three answers.
///
/// Nothing here mutates the user's library and nothing here reads Photos'
/// databases: a read is an asset fetch plus a `PHImageManager` video request, and
/// a write is `FileManager` on a directory this tool owns. See the two governing
/// rules in `docs/ARCHITECTURE.md`.
///
/// `@unchecked Sendable` because `AVAssetImageGenerator` and `AVAssetExportSession`
/// are documented as thread-safe for the operations used here but are not marked
/// `Sendable`, and every one of them is created per call and never shared. The
/// only shared mutable state is the eviction lock, which is a lock.
final class VideoLibrary: @unchecked Sendable {
    /// The instance the routes and the library layer use.
    ///
    /// `init` stays available rather than private — `PhotoLibrary` hides its own,
    /// but a type that both the router and the scan reach for should not force
    /// them through a global if a test ever wants an isolated one.
    static let shared = VideoLibrary()

    init() {}

    // MARK: - Cache bounds

    /// Ceiling on the total size of `AppPaths.videoCacheDirectory`.
    ///
    /// 2 GB, not "whatever is left on the disk". This cache exists to save one
    /// iCloud fetch per play; it is not storage, and nothing in it is
    /// irreplaceable. On a library with 4K clips the 32-file ceiling below bites
    /// long before this one does, and on a library of 3-minute clips this one
    /// bites at about a hundred files — which is roughly where re-fetching stops
    /// costing more than the bytes are worth.
    static let maxCacheBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Ceiling on the number of exports.
    ///
    /// A file count and a byte count bound different things: this one bounds the
    /// number of *inodes* and directory entries a long session leaves behind, and
    /// it bounds the worst case for someone whose clips are small — 32 × 3 MB is
    /// 96 MB, comfortably inside the byte ceiling, so without this the cache could
    /// hold thousands of files.
    static let maxCacheFiles = 32

    /// Serialises eviction, so two concurrent inserts cannot each compute a
    /// "current" total that includes the other's file and both decide to stop.
    private let evictionLock = OSAllocatedUnfairLock(initialState: ())

    // MARK: - Metadata

    /// Seconds, or nil when the asset is not a video or is not in the library.
    ///
    /// `async` for call-site uniformity with the rest of the library layer rather
    /// than because anything suspends: `PHAsset.fetchAssets(withLocalIdentifiers:)`
    /// is synchronous and cheap, and wrapping it in a continuation would add a
    /// suspension point — and a second place a continuation could be resumed twice
    /// — for no gain.
    func duration(identifier: String) async -> Double? {
        guard let asset = PhotoLibrary.shared.asset(identifier: identifier),
              asset.mediaType == .video else { return nil }
        // Returned as Photos reports it, including `0`. A video this old, or this
        // damaged, that Photos says is zero-length is a fact about the asset and
        // the caller decides what to do with it; inventing a `nil` here would turn
        // "broken clip" into "not a video", which the caller cannot tell apart
        // from a genuinely absent asset.
        return asset.duration
    }

    // MARK: - Frames

    /// One decoded frame at `seconds`, bounded to `maxPixelSize` on the longest
    /// edge.
    ///
    /// Honours `allowNetwork` exactly as the image path does, and with the same
    /// failures: `.imageNotLocal` when the pixels are in iCloud and the caller did
    /// not permit a download, `.imageUnavailable` when Photos has nothing to give
    /// and could not fetch it. That is not a courtesy to the caller — it is what
    /// lets `AnalysisEngine.recordOutcome` route an iCloud-only clip to
    /// `unavailable` instead of counting a scoring failure, exactly as it does for
    /// a photo.
    func frame(identifier: String,
               at seconds: Double,
               maxPixelSize: Int,
               allowNetwork: Bool) async throws -> CGImage {
        let asset = try await videoAsset(identifier: identifier, allowNetwork: allowNetwork)
        try Task.checkCancellation()

        // **A generator per call.** `AVAssetImageGenerator` caches decoded
        // renditions and its `copyCGImage` is documented as safe to call from
        // several threads on one instance, but "safe" is not "the same answer":
        // a shared generator's internal cache means the frame returned for a given
        // time can depend on what was decoded before it, and the whole point of
        // choosing the times by hand is that the frame is the frame. It is also
        // what makes a re-scan of an unchanged clip reproduce its score exactly.
        let generator = AVAssetImageGenerator(asset: asset)
        // Portrait video is stored with rotated sample data and a rotation matrix
        // in the track's preferred transform. Without this the generator hands
        // back a landscape frame for a portrait clip, and Vision would score the
        // clip lying on its side — a lower score for the wrong picture, and a
        // thumbnail that does not match what the lightbox plays.
        generator.appliesPreferredTrackTransform = true
        // Zero tolerance, both ways. The default tolerance is a full keyframe's
        // worth of seconds, which means the generator may return the nearest frame
        // it can decode *quickly* rather than the one that was asked for: the
        // sampled image would then depend on decode timing, and the score would
        // not be reproducible. The times are chosen, not approximated.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // `maximumSize` scales the transformed image down preserving aspect ratio,
        // so a square bound is the correct way to express "longest edge at most
        // this" — and it needs no track inspection to compute, which is what keeps
        // a rotated clip from being bounded on its stored dimensions.
        generator.maximumSize = CGSize(width: max(1, maxPixelSize), height: max(1, maxPixelSize))

        do {
            // The `async` form rather than `copyCGImage(at:actualTime:)`: the
            // synchronous one blocks a thread, and a blocked cooperative-pool
            // thread is one the analysis workers cannot have — the argument
            // `WalkHandoff` exists to make about the library walk.
            let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            return image
        } catch {
            // A decode failure is reported as `.imageUnavailable`, not as the
            // raw `AVError`: `recordOutcome` matches on the PhotoKit-facing
            // cases, and an unrecognised error would be counted as a scoring
            // failure and retried forever against a clip that will never decode.
            if Task.isCancelled { throw CancellationError() }
            throw PhotoLibraryError.imageUnavailable
        }
    }

    /// 1…3 ascending times, in seconds, spread across the clip and clamped inside
    /// it.
    ///
    /// The clip is not one frame, and the first frame usually is not the picture:
    /// a clip begins with a black or blue leader, a fade up from black, or the
    /// camera still coming up to speed. A single sample of such a frame scores the
    /// leader rather than the video, which for a two-second clip is most of it.
    /// Three samples with the median taken (`VisionAnalyzer.analyzeFrames`) means
    /// one bad frame cannot decide the score: the median of three ignores an
    /// outlier by construction, where a mean would let a black frame drag a good
    /// clip's score down by a third.
    ///
    /// **Why these fractions.** 10% / 50% / 90% rather than a fixed number of
    /// seconds from the start: a fixed offset samples only the head of a long clip
    /// and can miss the shot entirely, while fractions scale with the clip so a
    /// three-second clip and a three-minute clip are both sampled across their
    /// whole length. 90% rather than 100% is for the same reason the clamp below
    /// exists — the last frames of a clip are as likely to be a fade-out as the
    /// first are a leader.
    ///
    /// **Why the clamp.** `0...max(0, d - 0.05)` puts the last sample at least
    /// 50 ms inside the clip. Asking for a frame at or past the end of a track
    /// makes the generator return the final frame *and* report a failure, which
    /// would otherwise turn every clip shorter than about 0.5 s into one that logs
    /// a warning per sample. Duplicates are dropped rather than deduplicated after
    /// sorting, so a short clip yields fewer moments instead of the same frame
    /// three times — three identical samples have a median, but it is a median of
    /// one observation wearing three hats, and pretending otherwise would let the
    /// "one bad frame cannot decide the score" claim hide behind a duplicate.
    ///
    /// Never empty: `d` of `0` yields `[0]`, and `0` is a legal position to
    /// decode. `framesForAnalysis` depends on that.
    ///
    /// `static` and pure so it can be tested without a library, a clip, or a
    /// Photos permission.
    static func representativeTimes(duration: Double) -> [Double] {
        // `max(0, duration)` rather than trusting the caller: `PHAsset.duration`
        // is a `Double` off a foreign boundary, and a negative or NaN value would
        // otherwise produce an empty array — which `framesForAnalysis` treats as
        // "every frame failed" and reports as a failure for an asset that is fine.
        // `max` is not `Swift.max`'s total order here, so NaN is normalised
        // explicitly below.
        let d = duration.isFinite ? max(0, duration) : 0
        let ceiling = max(0, d - 0.05)
        var times: [Double] = []
        times.reserveCapacity(3)
        for fraction in [0.1, 0.5, 0.9] {
            let candidate = (d * fraction).clamped(to: 0...ceiling)
            if !times.contains(candidate) { times.append(candidate) }
        }
        return times.sorted()
    }

    // MARK: - Export

    /// A playable file on local disk for `identifier`, exporting on first request.
    ///
    /// ## Passthrough, and why the alternative was rejected
    ///
    /// `AVAssetExportPresetPassthrough` does not re-encode: the output is the
    /// original's sample data in a container, which makes it fast — the bytes are
    /// copied, not decoded — and lossless, so nothing degrades across repeated
    /// plays. The cost is that whatever Photos stored is what the browser gets,
    /// including HEVC, which Safari and WKWebView play and Chrome does not. That
    /// is accepted: the shipped presentation *is* WKWebView (see
    /// `PhotoCleanerApp`), and transcoding a 4 GB clip to H.264 on a click is
    /// minutes of CPU and a temporary file the same size as the original, which is
    /// a far worse thing to hand someone who pressed Play than a codec their
    /// browser may not take.
    ///
    /// ## Why it is cached at all
    ///
    /// Without a cache, playing a clip that is iCloud-only downloads it from
    /// Photos *per request* — and `/api/photo/{id}/video` is a Range route, so
    /// seeking re-requests, and Safari's own media-element probing can issue
    /// several. The cache makes the fetch happen once per identifier per eviction
    /// cycle, which is the only reason this directory is bounded rather than
    /// endless.
    ///
    /// ## Why the bound is here rather than in the OS
    ///
    /// Application Support is not `Caches`, so nothing will empty it for us; see
    /// `AppPaths.videoCacheDirectory`. On a library with tens of thousands of
    /// clips, an unbounded directory is a disk-fill bug that shows up as
    /// PhotoCleaner's fault and is not fixed by quitting. `enforceBounds` runs on
    /// every insert and evicts least-recently-used until the directory is inside
    /// both ceilings, logging each eviction.
    ///
    /// Concurrent requests for the same identifier are *not* coalesced. Both
    /// export to their own temporary file and then race to install it, and the
    /// loser discards its copy; the alternative — a per-identifier in-flight
    /// registry so the second caller waits — is a second concurrency mechanism
    /// with its own cancellation story, and the thing it saves is duplicated work
    /// on a click a user is not going to make twice. Every failure mode that a
    /// naive implementation would have here — a half-written file served to a
    /// player, or two exports clobbering each other's bytes — is prevented by
    /// exporting to a unique temporary name and installing with a move that is
    /// only ever a rename.
    func exportedFile(identifier: String, allowNetwork: Bool) async throws -> URL {
        let destination = cachedFileURL(identifier: identifier)
        // Cache hit. Touching the modification date is what makes the eviction
        // below actually least-recently-*used* rather than least-recently-
        // exported; it is a metadata write of a few bytes and costs nothing next
        // to the streaming read it precedes.
        if FileManager.default.fileExists(atPath: destination.path) {
            touch(destination)
            return destination
        }

        let asset = try await videoAsset(identifier: identifier, allowNetwork: allowNetwork)
        // `PHAssetResourceManager` and the `AVAssetExportSession` API it feeds are
        // both deprecated in favour of `AVAssetExportSession.export(to:as:)`
        // driven from a plain `AVURLAsset`, but the replacement loses the one
        // thing this needs: it cannot ask Photos for the bytes, only read a file
        // that already exists. `requestAVAsset` is what lets an iCloud-only clip
        // be played with downloads permitted at all.
        let export = try await export(asset: asset, identifier: identifier, allowNetwork: allowNetwork)
        // The export owns its temporary file — see `export`, which deliberately does
        // not clean it up on the way out — so every exit from here has to dispose of
        // it. `install` moves it on success, which consumes it; a throw between the
        // two would otherwise leave a whole clip's worth of bytes in the cache
        // directory under a name nothing will ever look up, counted against the
        // eviction bound until the next pass happens to collect it.
        do {
            try install(export, at: destination)
        } catch {
            try? FileManager.default.removeItem(at: export)
            throw error
        }
        enforceBounds()
        return destination
    }

    /// Byte length of the cached export, or nil when nothing is cached.
    ///
    /// Never exports, never touches the network: it answers "is this already on
    /// disk, and how much of it", which is what the streaming route needs to build
    /// a `Content-Length` and a `Content-Range` *before* opening a file it may
    /// not be able to open.
    func cachedByteCount(identifier: String) -> Int64? {
        let url = cachedFileURL(identifier: identifier)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// Drops one identifier's cached export. Called by the integrator on deletion.
    ///
    /// A deleted asset's bytes are the one thing in this directory that will never
    /// be wanted again, so this is not merely tidiness: without it, deleting every
    /// clip in a library leaves behind however many gigabytes they occupied until
    /// some later insert happened to evict them. Best effort — a file that is
    /// already gone, or a directory that cannot be written, is not an error worth
    /// reporting to a user who just deleted a photograph.
    func evict(identifier: String) {
        let url = cachedFileURL(identifier: identifier)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            Log.info("evicted the cached export for \(identifier)")
        } catch {
            Log.warn("could not evict the cached export for \(identifier): \(error.localizedDescription)")
        }
    }

    // MARK: - Cache internals

    /// Where one identifier's export lives.
    ///
    /// The name is a **sanitised digest of the identifier** plus the extension
    /// Photos reports, and both halves are load-bearing:
    ///
    /// - The identifier itself cannot be the name. A `PHAsset.localIdentifier`
    ///   contains `/` (`…/L0/001`), so using it verbatim would put the file in a
    ///   subdirectory that does not exist — or, after any future path
    ///   normalisation, outside this one. Every byte is mapped to a lower-case hex
    ///   digit pair instead, which is injective (no two identifiers can produce the
    ///   same name) and needs no escaping rules to stay true. Injective rather than
    ///   merely short: a hashed name would be shorter, and a collision would serve
    ///   one person's video for another's — so this is not a hash, and the length
    ///   it costs is 2×41 characters.
    /// - The extension comes from Photos rather than being assumed, because the
    ///   streaming route derives its MIME type from it and `WKWebView` decides
    ///   whether it can play the bytes by the same thing. Guessing `.mov` and
    ///   writing an `.mp4` would produce a 206 with a plausible-looking
    ///   `video/quicktime` header that the player refuses.
    private func cachedFileURL(identifier: String) -> URL {
        AppPaths.videoCacheDirectory
            .appendingPathComponent(Self.digest(identifier))
            .appendingPathExtension(Self.reportedExtension(identifier: identifier))
    }

    /// Hex of every byte of the identifier. See `cachedFileURL` for why this is a
    /// re-encoding rather than a hash.
    static func digest(_ identifier: String) -> String {
        let hex = "0123456789abcdef"
        var out = ""
        out.reserveCapacity(identifier.utf8.count * 2)
        for byte in identifier.utf8 {
            out.append(hex[hex.index(hex.startIndex, offsetBy: Int(byte >> 4))])
            out.append(hex[hex.index(hex.startIndex, offsetBy: Int(byte & 0x0f))])
        }
        return out
    }

    /// The extension Photos reports for this asset's video resource, sanitised.
    ///
    /// Falls back to `.mov` when Photos has no resource to ask or reports a name
    /// with no usable extension — `AVAssetExportPresetPassthrough` produces a
    /// QuickTime container in that case, so the fallback is what the bytes will
    /// actually be rather than a guess.
    private static func reportedExtension(identifier: String) -> String {
        let fallback = "mov"
        guard let asset = PhotoLibrary.shared.asset(identifier: identifier) else { return fallback }
        guard let name = videoResource(for: asset)?.originalFilename else { return fallback }
        let candidate = (name as NSString).pathExtension.lowercased()
        let safe = candidate.filter { $0.isLetter || $0.isNumber }
        // Capped at eight characters, which is longer than any container Photos
        // reports (`mov`, `mp4`, `m4v`, `qt`) and short enough that the digest
        // plus the extension stays well inside the 255-byte filename limit.
        return safe.isEmpty || safe.count > 8 ? fallback : safe
    }

    /// The `PHAssetResource` that is this asset's video.
    ///
    /// `.video`, `.fullSizeVideo` and `.pairedVideo` are all accepted, because
    /// which one Photos reports depends on the asset rather than on anything this
    /// tool controls: an ordinary clip is `.video`, a Live Photo's motion asset is
    /// `.pairedVideo` (and is reached through its parent image, so it never
    /// arrives here), and an iCloud-optimised library can report the full-size
    /// original separately. Preferring the **full-size** variant over a
    /// lower-quality one matters because a passthrough export of a thumbnail-sized
    /// rendition is a video that looks like a slideshow.
    private static func videoResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let video = resources.filter { resource in
            switch resource.type {
            case .video, .fullSizeVideo, .pairedVideo: return true
            default: return false
            }
        }
        return video.first { $0.type == .fullSizeVideo } ?? video.first
    }

    /// Evicts least-recently-used exports until the directory is inside both
    /// ceilings.
    ///
    /// "Least recently used" is the modification date, which `touch` refreshes on
    /// every cache hit — so a clip the user keeps coming back to survives and a
    /// clip they opened once does not. Sorting by *size* instead would keep the
    /// cheap files and throw away the expensive ones, which is backwards: the
    /// expensive file is the one that cost an iCloud download to produce.
    ///
    /// Runs on **insert** only. Checking on read would put a directory scan on the
    /// path of every play, and reading does not grow the cache, so there is nothing
    /// for a read-triggered pass to fix that the next insert will not.
    private func enforceBounds() {
        evictionLock.withLock {
            let fm = FileManager.default
            let directory = AppPaths.videoCacheDirectory
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            guard let entries = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]) else { return }

            // Newest last, so eviction walks from the oldest. The file just
            // installed is the newest in the directory and therefore the last
            // candidate — it is never evicted by the pass that created it, which is
            // the one invariant that makes this safe to run inside `exportedFile`
            // rather than on a timer.
            let dated = entries.compactMap { url -> (url: URL, date: Date, bytes: Int64)? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { return nil }
                return (url, values.contentModificationDate ?? .distantPast,
                        Int64(values.fileSize ?? 0))
            }.sorted { $0.date < $1.date }

            var total = dated.reduce(Int64(0)) { $0 + $1.bytes }
            var index = 0
            // Both ceilings are tested against what is **left**, not against the
            // count this pass started with. Reading `dated.count` here instead —
            // which is the natural-looking spelling — makes the loop condition
            // invariant to its own progress: with 40 files it asks to evict while
            // 40 > 32, removes some, and then still sees 40 and keeps going until
            // the directory is *empty*, deleting the file this pass was called to
            // create. A cache that empties itself on insert is worse than no cache.
            while index < dated.count,
                  total > Self.maxCacheBytes || dated.count - index > Self.maxCacheFiles {
                let victim = dated[index]
                index += 1
                // The file that triggered this pass is protected by the sort order,
                // not by a name check — it is the newest entry, so it is the last
                // candidate and is only reached if every older file is already gone.
                do {
                    try fm.removeItem(at: victim.url)
                    total -= victim.bytes
                    Log.info("evicted a cached video export (\(victim.bytes) bytes); "
                             + "\(dated.count - index) file(s) left, \(total) bytes")
                } catch {
                    // Not fatal, and not worth aborting the pass over: the file that
                    // could not be removed is still counted in `dated.count - index`,
                    // so the next insert tries again rather than believing it.
                    Log.warn("could not evict \(victim.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    // MARK: - PhotoKit plumbing

    /// The `AVAsset` for a video, from Photos, honouring `allowNetwork`.
    ///
    /// `requestAVAsset` rather than `PHAssetResourceManager.writeData(for:toFile:)`:
    /// the resource manager hands over a *file*, and building one means choosing a
    /// directory and a name for it, which is a cache's job, not a request's. This
    /// returns something AVFoundation can read from wherever it likes.
    ///
    /// `deliveryMode: .highQualityFormat` for the same reason the image path uses
    /// it: `.fastFormat` can hand back a low-resolution rendition, and a passthrough
    /// export of *that* is a small, blurry video that looks like a bug rather than
    /// like a cache miss.
    private func videoAsset(identifier: String, allowNetwork: Bool) async throws -> AVAsset {
        guard let asset = PhotoLibrary.shared.asset(identifier: identifier) else {
            throw PhotoLibraryError.assetNotFound
        }
        guard asset.mediaType == .video else { throw PhotoLibraryError.assetNotFound }

        // `ResumeBox`'s shape, rebuilt here rather than shared, because the one in
        // `PhotoLibrary` is file-private to that file and this file must not reach
        // into it. PhotoKit documents this handler as being called once, but may
        // call it more than once in practice, and a second `resume` of a *checked*
        // continuation is a process abort — not a catchable error, not a crash
        // report, an abort that takes the whole app down mid-scan. The guard costs
        // one atomic flag.
        let box = VideoRequestBox()
        let wrapper: HandedOff<AVAsset> = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let options = PHVideoRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.version = .current
                options.isNetworkAccessAllowed = allowNetwork
                let requestID = PHImageManager.default().requestAVAsset(forVideo: asset, options: options) {
                    avAsset, _, info in
                    guard box.beginResume() else { return }
                    if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                        // The *task* was cancelled, which is not the asset's fault.
                        // `AnalysisEngine` checks `Task.isCancelled` before it routes
                        // anything, so this must not look like a broken image.
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if let avAsset {
                        continuation.resume(returning: HandedOff(avAsset))
                        return
                    }
                    if let error = info?[PHImageErrorKey] as? Error {
                        let nsError = error as NSError
                        let isCloud = nsError.domain == PHPhotosErrorDomain
                            && (nsError.code == PHPhotosError.networkAccessRequired.rawValue
                                || nsError.code == PHPhotosError.networkError.rawValue)
                        continuation.resume(throwing: isCloud
                            ? PhotoLibraryError.imageNotLocal
                            : PhotoLibraryError.imageRequestFailed(error.localizedDescription))
                        return
                    }
                    if info?[PHImageResultIsInCloudKey] as? Bool == true, !allowNetwork {
                        continuation.resume(throwing: PhotoLibraryError.imageNotLocal)
                        return
                    }
                    continuation.resume(throwing: PhotoLibraryError.imageUnavailable)
                }
                box.set(requestID: requestID)
            }
        } onCancel: {
            box.cancel()
        }
        return wrapper.value
    }

    /// Passthrough-exports `asset` to a fresh temporary file and returns it.
    ///
    /// The result is *not* in its final location: `install` does that. Exporting
    /// straight to the cached path would leave a partially-written file under the
    /// name a streaming request is about to serve, and a player that opened it
    /// would see a truncated container — the kind of failure that looks like
    /// corruption of the user's video rather than like a race in this tool.
    private func export(asset: AVAsset,
                        identifier: String,
                        allowNetwork: Bool) async throws -> URL {
        _ = allowNetwork  // `videoAsset` already applied it; the session has no such option.
        let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
        guard let session else { throw PhotoLibraryError.imageUnavailable }

        // Passthrough can only write container types that fit the samples it was
        // given, so the choice is among `supportedFileTypes` and never above it.
        // Photos' own extension is preferred so the cached name and the bytes
        // agree; when Photos reports an extension the session cannot write — an
        // unusual container, or a `.MOV` Photos calls something else — the file is
        // named after what was *actually* written rather than after what Photos
        // said, because a wrong extension means a wrong MIME type from the
        // streaming route and a player that refuses perfectly good bytes.
        let fileType = Self.preferredFileType(for: session.supportedFileTypes,
                                              originalExtension: Self.reportedExtension(identifier: identifier))

        try AppPaths.createDirectoryIfNeeded(AppPaths.videoCacheDirectory)
        let fm = FileManager.default
        // A unique name, because two concurrent requests for one identifier both
        // export and both try to install; see `exportedFile` for why they are not
        // coalesced.
        let temporary = AppPaths.videoCacheDirectory
            .appendingPathComponent("\(Self.digest(identifier)).\(UUID().uuidString)")
            .appendingPathExtension(Self.pathExtension(for: fileType))

        // ## The temporary file is the caller's to clean up, deliberately
        //
        // There is no `defer` removing it here, and that is load-bearing. A `defer`
        // in this function would delete the export **before** the caller ever sees
        // the URL: `defer` runs when the scope exits, which is after the return value
        // is computed and before control actually reaches the caller. So the sequence
        // would be "export → compute the URL → *delete the file* → return the URL of
        // a file that no longer exists", and `install` would then fail with
        // `NSCocoaErrorDomain Code=4`, "the former doesn't exist" — on **every**
        // clip, with the bytes correctly written and then thrown away.
        //
        // So ownership passes to the caller: `exportedFile` installs the file (moving
        // it, which consumes the temporary) and removes it on any failure, and
        // nothing else can reach this path.
        //
        // Found by playing a real clip against a real library. Every test of this
        // code passed first, because the tests never went through `export` — they
        // covered the Range parser, the refusal gate and the cache-hit path, none of
        // which export anything. A test that seeds a file on disk cannot see a bug
        // that only exists while the file is being written.
        do {
            try await session.export(to: temporary, as: fileType)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
        guard fm.fileExists(atPath: temporary.path) else {
            try? fm.removeItem(at: temporary)
            throw PhotoLibraryError.imageUnavailable
        }
        return temporary
    }

    /// Moves an export into its cached name.
    ///
    /// The temporary file is already fully written, so this is a rename within one
    /// directory — atomic, which is the property that matters: a reader either sees
    /// no file or sees the whole file. If the destination already exists, another
    /// request won the race and its bytes are equally valid, so this one's copy is
    /// discarded and the existing file is used.
    private func install(_ temporary: URL, at destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { return }
        do {
            try fm.moveItem(at: temporary, to: destination)
        } catch {
            // Lost the race after the check above. Anything else is real.
            guard fm.fileExists(atPath: destination.path) else { throw error }
        }
        touch(destination)
    }

    /// Picks the container to export into, from what the session says it can write.
    static func preferredFileType(for supported: [AVFileType], originalExtension: String) -> AVFileType {
        if let match = supported.first(where: { pathExtension(for: $0) == originalExtension }) {
            return match
        }
        // `.mov` is the container passthrough writes for every QuickTime-family
        // sample type, so it is the right guess ahead of any other.
        if let quickTime = supported.first(where: { $0 == .mov }) { return quickTime }
        return supported.first ?? .mov
    }

    static func pathExtension(for fileType: AVFileType) -> String {
        switch fileType {
        case .mov: return "mov"
        case .mp4: return "mp4"
        case .m4v: return "m4v"
        default: return fileType.rawValue.lowercased()
        }
    }
}

/// Carries a value PhotoKit handed back across a task boundary.
///
/// `AVAsset` is not `Sendable`, so resuming one out of `requestAVAsset`'s
/// Objective-C callback into a checked continuation trips Swift 6's sending check:
/// the callback is not isolated, and the compiler cannot prove the value did not
/// travel. It is safe — `AVAsset` is documented as usable from any thread once
/// loaded, which is the same basis on which `PhotoLibrary` is
/// `@unchecked Sendable` — so this states that in one place rather than
/// suppressing the check at the call site, and `value` is `let`, so the box cannot
/// be a way to mutate it after the fact.
private struct HandedOff<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) { self.value = value }
}

/// Single-shot resume guard for one `requestAVAsset`, shared between PhotoKit's
/// handler and the task-cancellation handler.
///
/// The same hazard as `PhotoLibrary.ResumeBox`, and for the same reason: resuming
/// a checked continuation twice aborts the process. `set`/`cancel` re-check the
/// flag under the lock and act immediately if the request has already been
/// resolved, because a cancellation that arrives *before* `requestAVAsset` has
/// returned its identifier is the case a naive `if let id { cancel(id) }` drops —
/// and then the request runs to completion, does a cloud download nobody wanted,
/// and resumes a continuation whose task is already gone.
private final class VideoRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var requestID: PHImageRequestID?

    func beginResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }

    func set(requestID: PHImageRequestID) {
        lock.lock()
        let alreadyResolved = resumed
        self.requestID = requestID
        lock.unlock()
        if alreadyResolved { PHImageManager.default().cancelImageRequest(requestID) }
    }

    func cancel() {
        lock.lock()
        let id = requestID
        lock.unlock()
        if let id { PHImageManager.default().cancelImageRequest(id) }
    }
}

private extension Comparable {
    /// `self`, confined to `range`. `min`/`max` would do the same, but the
    /// argument order reads as a clamp only when it says `clamped`, and this is
    /// called on a `Double` that came from `PHAsset`.
    func clamped(to range: ClosedRange<Self>) -> Self {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
