import AppKit
import Foundation
import os
import Photos

enum PhotoLibraryError: Error, CustomStringConvertible {
    case notAuthorized(String)
    case assetNotFound
    case imageUnavailable
    /// Pixels live only in iCloud and network access was not granted for the request.
    case imageNotLocal
    case imageRequestFailed(String)
    case deletionFailed(String)

    var description: String {
        switch self {
        case .notAuthorized(let detail): return "Photos access is not authorized (\(detail))"
        case .assetNotFound: return "no such asset in the Photos library"
        case .imageUnavailable: return "the image data is not available locally"
        case .imageNotLocal: return "the asset is stored in iCloud only"
        case .imageRequestFailed(let detail): return "the image request failed: \(detail)"
        case .deletionFailed(let detail): return "PhotoKit refused the deletion: \(detail)"
        }
    }
}

/// `performChanges` refused a favourite change.
///
/// A separate type from `PhotoLibraryError` on purpose: that enum is matched
/// exhaustively in `AnalysisEngine.recordOutcome`, where every case routes an
/// *analysis* outcome, and a favourite write never reaches there. Adding a case
/// would have widened that switch for no benefit and put an unrelated possibility
/// on the analysis path's mind.
enum FavoriteChangeError: Error, CustomStringConvertible {
    case refused(String)

    var description: String {
        switch self {
        case .refused(let detail): return "PhotoKit refused to change the favorite flag: \(detail)"
        }
    }
}

/// All access to the user's photos flows through PhotoKit.
///
/// Nothing in this tool opens `Photos Library.photoslibrary`, reads its SQLite
/// databases, or touches image files on disk directly. Every read is an Asset
/// fetch plus an `PHImageManager` request; every write is a
/// `PHPhotoLibrary.performChanges` transaction.
///
/// `PHAsset`, `PHImageManager` and `PHPhotoLibrary` are documented as usable
/// from any thread, and this type keeps no mutable state of its own, so the
/// unchecked conformance holds.
final class PhotoLibrary: @unchecked Sendable {
    static let shared = PhotoLibrary()

    private let imageManager = PHImageManager.default()

    private init() {}

    // MARK: - Authorization

    /// The current status, without prompting.
    ///
    /// `requestAuthorization()` shows UI and must only ever be called from the
    /// launch sequence: an HTTP request handler must never be able to summon a
    /// TCC prompt just by sending a request.
    static func currentAuthorization() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Prompts on first use (the prompt is attributed to the app bundle, which
    /// is why PhotoCleaner ships as a `.app`). Returns the resulting status.
    static func requestAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current != .notDetermined { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    static func authorizationDescription(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .limited: return "limited"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    static func hasReadAccess(_ status: PHAuthorizationStatus) -> Bool {
        status == .authorized || status == .limited
    }

    // MARK: - Enumeration

    /// Walks the whole library, handing metadata to `consume` in batches.
    ///
    /// The walk streams, and protecting that is what this implementation is
    /// about. `enumerateObjects` is a synchronous callback API with no async
    /// hand-off, so the batch boundary has to live somewhere between it and the
    /// `await consume(...)` below. `WalkHandoff` is that boundary: exactly one
    /// batch is in flight, the walk thread parks until the consumer has finished
    /// with it, and at most one batch is being filled alongside. No `PHAsset` and
    /// no list of identifiers is ever accumulated, so resident memory stays flat
    /// in library size.
    ///
    /// The dedicated thread is not decoration. Back-pressure here means *blocking*
    /// a thread, and a blocked thread on the cooperative pool is a thread the rest
    /// of the program cannot have — while the consumer this walk feeds
    /// (`CacheStore`, plus the analysis workers) runs there. One dedicated thread
    /// per walk, which parks while the consumer catches up and returns when the
    /// walk ends, cannot starve anything.
    ///
    /// ## Why not index into the fetch result
    ///
    /// `PHFetchOptions` has `fetchLimit` but no `fetchOffset`, so there is no
    /// way to re-issue a bounded, offset fetch per batch: paging by index is
    /// the only way `PHFetchResult` can be walked in slices.
    ///
    /// That walk is not safe. `result.count` is read once and the result is then
    /// indexed from 0 to `count - 1` across a walk that takes minutes on a large
    /// library, and `result.count` is not a constant: this library was measured
    /// losing assets while a probe held one result open (53,241 → 53,239 →
    /// 53,238 over ~40 s). If the library shrinks, the last `objects(at:)` slice
    /// runs off the end and `-[NSArray objectsAtIndexes:]` answers with an
    /// `NSRangeException` — an Objective-C exception, so uncatchable in Swift and
    /// fatal to the process. Measured, not hypothesised:
    ///
    ///     *** Terminating app due to uncaught exception 'NSRangeException',
    ///         reason: 'index 53250 in index set beyond bounds [0 .. 53240]'
    ///
    /// `enumerateObjects` has no index to go stale: PhotoKit decides what to hand
    /// the block, so an asset that disappears mid-walk is simply not visited and
    /// one that appears may be. A scan that races a mutation then under- or
    /// over-reports for that run and the next scan reconciles it — the same
    /// outcome as any live view of a changing library. (The abort could not reach
    /// `finishScan`, so it never deleted rows; the blast radius was bounded. It
    /// was still an abort, every time it happened.)
    func enumerateImages(batchSize: Int = 512,
                         consume: @Sendable ([ScanRecord]) async throws -> Void) async throws {
        // Back-pressure lives in `WalkHandoff`, not in the buffering policy. See
        // its documentation for why a bounded buffer is the wrong tool here.
        let stop = WalkCancellation()
        let handoff = WalkHandoff<ScanRecord>()
        let batch = ScanRecordBatch(capacity: max(1, batchSize))

        let producer = Thread {
            PhotoLibrary.fetchImages().enumerateObjects { asset, _, enumerationStop in
                if stop.isRequested {
                    enumerationStop.pointee = true
                    return
                }
                batch.append(PhotoLibrary.scanRecord(for: asset))
                guard batch.isFull else { return }
                // Parks here while the consumer is behind. `handOff` only
                // returns false once the reader is gone for good, so this cannot
                // drop a batch and then carry on.
                if !handoff.handOff(batch.take()) {
                    enumerationStop.pointee = true
                }
            }
            // The tail the walk finished without filling a batch over.
            if !batch.isEmpty { _ = handoff.handOff(batch.take()) }
            handoff.close()
        }
        producer.name = "com.alastorid.photocleaner.library-walk"
        producer.start()

        // `stop.request()` makes a producer that is part-way through PhotoKit's
        // enumeration leave at the next asset; `close()` unparks one waiting for
        // the consumer and finishes the stream. Both are idempotent, so running
        // them after the walk finished normally changes nothing — and both are
        // required on the throwing path too, or a `consume` that throws would
        // leave the walk thread parked on the semaphore for the life of the
        // process.
        defer {
            stop.request()
            handoff.close()
        }
        for try await batch in handoff.batches {
            try Task.checkCancellation()
            try await consume(batch)
            // Releasing the producer *after* `consume` is what makes this
            // back-pressure rather than a pipeline: at most one batch is in
            // flight, so the walk cannot outrun the cache and buffer up the
            // whole library.
            handoff.release()
        }
        // The loop above is NOT a completion signal. Measured: cancelling the
        // consuming task makes `AsyncThrowingStream.Iterator.next()` return nil,
        // so a `for try await` over a stream exits *normally* rather than
        // throwing — a cancelled walk and a finished walk are indistinguishable
        // from here. That distinction is load-bearing: `AnalysisEngine.scan`
        // calls `finishScan` only when this returns, and `finishScan` deletes
        // every cache row not stamped by this walk. Trusting the loop's exit
        // would let a quit or a rescan mid-scan delete the scores of every photo
        // the walk had not reached yet. The per-batch `checkCancellation` above
        // cannot cover the case where cancellation arrives while the reader is
        // parked, so the check has to be repeated after the loop.
        try Task.checkCancellation()
    }

    /// The one fetch the walk iterates. Sorted newest first, which is the order
    /// `CacheStore.claimJobs` drains the queue in, so the queue and the scan
    /// agree on what "next" means.
    private static func fetchImages() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(with: .image, options: options)
    }

    private static func scanRecord(for asset: PHAsset) -> ScanRecord {
        ScanRecord(
            identifier: asset.localIdentifier,
            mediaType: asset.mediaType.rawValue,
            creationDate: asset.creationDate?.timeIntervalSince1970,
            modificationDate: asset.modificationDate?.timeIntervalSince1970,
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            favorite: asset.isFavorite,
            mediaSubtype: Int(asset.mediaSubtypes.rawValue),
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)
        )
    }

    func asset(identifier: String) -> PHAsset? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        return result.firstObject
    }

    func assets(identifiers: [String]) -> [PHAsset] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    // MARK: - Images

    /// Requests a downscaled representation and returns it as a `CGImage`.
    ///
    /// `maxPixelSize` bounds the longest edge; the request is aspect-preserving,
    /// so no cropping occurs and memory per in-flight image is bounded by
    /// `maxPixelSize² × 4` bytes rather than by the original's dimensions.
    ///
    /// Measured behaviour of the option set: `.highQualityFormat` with
    /// `.exact` is the only combination that reliably returns *exactly* the
    /// requested size. `.fastFormat` can return a 64×48 embedded thumbnail,
    /// which is useless for a grid tile.
    ///
    /// Cancelling the surrounding Swift task cancels the PhotoKit request.
    func image(identifier: String, maxPixelSize: Int, allowNetwork: Bool) async throws -> CGImage {
        guard let asset = asset(identifier: identifier) else { throw PhotoLibraryError.assetNotFound }
        return try await image(asset: asset, maxPixelSize: maxPixelSize, allowNetwork: allowNetwork)
    }

    /// A large preview, degrading through smaller renditions rather than failing.
    ///
    /// In an optimised iCloud library the original may not be on this Mac while
    /// a smaller rendition is. Asking for one fixed size therefore produces
    /// spurious failures; walking down from the preferred size always yields the
    /// best representation Photos can actually produce locally.
    func previewImage(identifier: String, preferredPixelSize: Int, allowNetwork: Bool) async throws -> CGImage {
        let ladder = [preferredPixelSize, 1536, 1024, 768, 512].filter { $0 <= preferredPixelSize }
        var lastError: Error = PhotoLibraryError.imageUnavailable
        for size in ladder {
            do {
                return try await image(identifier: identifier, maxPixelSize: size, allowNetwork: allowNetwork)
            } catch let error as PhotoLibraryError {
                switch error {
                case .imageNotLocal, .imageUnavailable, .imageRequestFailed:
                    lastError = error
                    continue
                case .assetNotFound, .notAuthorized, .deletionFailed:
                    throw error
                }
            }
        }
        throw lastError
    }

    func image(asset: PHAsset, maxPixelSize: Int, allowNetwork: Bool) async throws -> CGImage {
        let target = PhotoLibrary.targetSize(for: asset, maxPixelSize: maxPixelSize)
        return try await requestImage(asset: asset, targetSize: target, allowNetwork: allowNetwork)
    }

    private static func targetSize(for asset: PHAsset, maxPixelSize: Int) -> CGSize {
        let width = CGFloat(max(asset.pixelWidth, 1))
        let height = CGFloat(max(asset.pixelHeight, 1))
        let longest = max(width, height)
        let scale = min(CGFloat(maxPixelSize) / longest, 1)
        return CGSize(width: max(1, (width * scale).rounded()),
                      height: max(1, (height * scale).rounded()))
    }

    private func requestImage(asset: PHAsset,
                              targetSize: CGSize,
                              allowNetwork: Bool) async throws -> CGImage {
        // `resumeOnce` guards the continuation: PhotoKit may invoke the handler
        // more than once (degraded then final, or image then error) and a second
        // resume of a checked continuation traps.
        let box = ResumeBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let options = PHImageRequestOptions()
                options.isSynchronous = false
                options.isNetworkAccessAllowed = allowNetwork
                options.version = .current
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .exact
                options.allowSecondaryDegradedImage = false

                let requestID = imageManager.requestImage(
                    for: asset,
                    targetSize: targetSize,
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    if let cancelled = info?[PHImageCancelledKey] as? Bool, cancelled {
                        if box.beginResume() {
                            continuation.resume(throwing: PhotoLibraryError.imageUnavailable)
                        }
                        return
                    }
                    if let image, let cgImage = PhotoLibrary.cgImage(from: image) {
                        if box.beginResume() { continuation.resume(returning: cgImage) }
                        return
                    }
                    let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                    if degraded { return }  // wait for the final representation
                    // Photos tells us explicitly when the pixels were never on
                    // this Mac; that is a normal, expected state, not an error.
                    if info?[PHImageResultIsInCloudKey] as? Bool == true, !allowNetwork {
                        if box.beginResume() { continuation.resume(throwing: PhotoLibraryError.imageNotLocal) }
                        return
                    }
                    if let error = info?[PHImageErrorKey] as? Error {
                        if box.beginResume() {
                            let nsError = error as NSError
                            // 3164: pixels are in iCloud and network access was
                            // not granted. 3169: the fetch over the network failed.
                            let isCloud = nsError.domain == PHPhotosErrorDomain
                                && (nsError.code == PHPhotosError.networkAccessRequired.rawValue
                                    || nsError.code == PHPhotosError.networkError.rawValue)
                            continuation.resume(throwing: isCloud
                                ? PhotoLibraryError.imageNotLocal
                                : PhotoLibraryError.imageRequestFailed(error.localizedDescription))
                        }
                        return
                    }
                    if box.beginResume() { continuation.resume(throwing: PhotoLibraryError.imageNotLocal) }
                }
                box.set(requestID: requestID, manager: imageManager)
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// `NSImage` → `CGImage` without re-rendering the bitmap representation.
    private static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: - Deletion

    struct DeletionOutcome: Sendable {
        var requested: Int = 0
        var deleted: Int = 0
        var missing: Int = 0
        /// Assets that exist in Photos but were left alone because they are
        /// favourites and protection is on. Read live from PhotoKit, so a photo
        /// favourited since the last scan is still protected.
        var skippedFavorites: Int = 0
        /// Assets that exist but are not still images. Version 1 only ever scans
        /// `.image`, so this is zero unless the cache and the library have
        /// diverged — in which case deleting them is not what anyone asked for.
        var skippedNonImages: Int = 0
        var deletedIdentifiers: [String] = []
        var failedMessages: [String] = []
    }

    /// Deletes through `PHPhotoLibrary.performChanges`, in bounded chunks.
    ///
    /// Photos/iCloud applies its own semantics afterwards: removed from the
    /// library, moved to "Recently Deleted", synced to the user's other devices.
    /// Chunking means one bad batch cannot abort the whole operation, and the
    /// caller can report exactly what happened: a failed chunk is counted and
    /// described, never folded into the deleted total.
    ///
    /// Favourite protection is enforced *here* as well as in the cache, because
    /// the cached `favorite` flag is only as fresh as the last scan. PhotoKit is
    /// the authority on what is favourited right now, and a photo that became a
    /// favourite a minute ago must not be destroyed because the cache has not
    /// caught up.
    func delete(identifiers: [String], protectFavorites: Bool, chunkSize: Int = 500) async -> DeletionOutcome {
        var outcome = DeletionOutcome()
        // Duplicates must never be double counted: `fetchAssets` collapses them,
        // which would leave `deleted` and `deletedIdentifiers` disagreeing.
        var seen = Set<String>()
        let unique = identifiers.filter { seen.insert($0).inserted }
        outcome.requested = unique.count

        let authorization = Self.currentAuthorization()
        guard Self.hasReadAccess(authorization) else {
            outcome.failedMessages.append(
                "Photos access is not authorized (\(Self.authorizationDescription(authorization)))")
            return outcome
        }

        for chunk in unique.chunked(into: chunkSize) {
            let fetched = assets(identifiers: chunk)
            let found = Set(fetched.map(\.localIdentifier))
            outcome.missing += chunk.count - found.count
            guard !fetched.isEmpty else { continue }

            var deletable: [PHAsset] = []
            for asset in fetched {
                if protectFavorites, asset.isFavorite {
                    outcome.skippedFavorites += 1
                } else if asset.mediaType != .image {
                    outcome.skippedNonImages += 1
                } else {
                    deletable.append(asset)
                }
            }
            guard !deletable.isEmpty else { continue }

            do {
                try await performDeletion(deletable)
                outcome.deleted += deletable.count
                let removed = Set(deletable.map(\.localIdentifier))
                outcome.deletedIdentifiers.append(contentsOf: chunk.filter { removed.contains($0) })
            } catch {
                let message = "a batch of \(deletable.count) assets was not deleted: \(error.localizedDescription)"
                outcome.failedMessages.append(message)
                Log.error("deletion chunk failed (\(deletable.count) assets): \(error.localizedDescription)")
            }
        }
        return outcome
    }

    // MARK: - Favourite flags

    /// Outcome of setting or clearing the favourite flag.
    struct FavoriteOutcome: Sendable {
        /// Distinct identifiers the caller asked about.
        var requested = 0
        /// Assets PhotoKit is now reporting as favourites matching the requested
        /// state. Read back from PhotoKit *after* the change, never assumed from
        /// the request: this is what the caller writes into the cache, so the two
        /// cannot come to disagree about who is protected.
        var confirmed: [String: Bool] = [:]
        /// Assets that exist but are no longer still images.
        var skippedNonImages = 0
        /// Identifiers no longer in the library at all.
        var missing: Int = 0
        /// One message per chunk that PhotoKit refused, naming the batch size.
        var failedMessages: [String] = []
    }

    /// Sets or clears `isFavorite` through PhotoKit, in bounded chunks.
    ///
    /// This is a genuine *write* to the user's library and gets the same care as
    /// deletion: bounded chunks, per-chunk error reporting, and the cache updated
    /// only from what PhotoKit confirms afterwards.
    ///
    /// ## Why the confirmation re-read matters
    ///
    /// `performChanges` reporting `success: true` means PhotoKit accepted the
    /// change request, not that a re-fetch will observe it — Photos can be
    /// mid-sync, or the fetch can be served from a snapshot taken before the
    /// commit. Writing the *requested* value into the cache instead of the
    /// observed one is how a cache and the library come to disagree about
    /// protection, so every identifier in a successful chunk is re-fetched and its
    /// actual `isFavorite` returned. The caller persists those, which means:
    ///
    /// - a confirmed favourite is in the cache as a favourite, and
    /// - an asset PhotoKit did not actually change is *not* recorded as changed.
    ///
    /// The disagreement that could ever endanger a photo cannot arise: clearing a
    /// favourite is the only direction that weakens protection, and this reports
    /// what Photos actually holds, so the cache never gains protection the library
    /// does not grant nor loses it while the library still has it. Independently,
    /// `delete` re-reads `isFavorite` live at the point of destruction.
    ///
    /// Setting a favourite twice is a no-op in PhotoKit, so `favorite: true` on an
    /// asset that is already a favourite is reported as confirmed and not as an
    /// error; the same for clearing one that is not a favourite.
    func setFavorite(identifiers: [String], favorite: Bool, chunkSize: Int = 500) async -> FavoriteOutcome {
        var outcome = FavoriteOutcome()
        var seen = Set<String>()
        let unique = identifiers.filter { seen.insert($0).inserted }
        outcome.requested = unique.count

        let authorization = Self.currentAuthorization()
        guard Self.hasReadAccess(authorization) else {
            outcome.failedMessages.append(
                "Photos access is not authorized (\(Self.authorizationDescription(authorization)))")
            return outcome
        }

        for chunk in unique.chunked(into: chunkSize) {
            let fetched = assets(identifiers: chunk)
            let found = Set(fetched.map(\.localIdentifier))
            outcome.missing += chunk.count - found.count
            guard !fetched.isEmpty else { continue }

            var targets: [PHAsset] = []
            for asset in fetched {
                if asset.mediaType == .image { targets.append(asset) } else { outcome.skippedNonImages += 1 }
            }
            guard !targets.isEmpty else { continue }

            do {
                try await performFavoriteChange(targets, favorite: favorite)
                // Confirm from PhotoKit rather than assuming the change landed.
                for asset in assets(identifiers: targets.map(\.localIdentifier)) {
                    outcome.confirmed[asset.localIdentifier] = asset.isFavorite
                }
            } catch {
                let message = "a batch of \(targets.count) assets kept their favorite flag: "
                    + error.localizedDescription
                outcome.failedMessages.append(message)
                Log.error("favorite chunk failed (\(targets.count) assets): \(error.localizedDescription)")
            }
        }
        return outcome
    }

    /// `PHAssetChangeRequest.favorite` is the documented way to change the flag.
    ///
    /// Assigning it inside `performChanges` and `false` outside does nothing —
    /// PhotoKit reads the request object at commit time — so the value is captured
    /// per asset here rather than set globally.
    private func performFavoriteChange(_ assets: [PHAsset], favorite: Bool) async throws {
        let box = ResumeBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                for asset in assets {
                    // `isFavorite`, not the Objective-C `favorite`: the Swift
                    // importer renamed it, and the old spelling is a hard error
                    // rather than a deprecated alias.
                    PHAssetChangeRequest(for: asset).isFavorite = favorite
                }
            } completionHandler: { success, error in
                guard box.beginResume() else { return }
                if success {
                    continuation.resume()
                } else {
                    let message = error?.localizedDescription ?? "unknown PhotoKit error"
                    continuation.resume(throwing: FavoriteChangeError.refused(message))
                }
            }
        }
    }

    // MARK: - Albums

    /// One PhotoKit album collection, as offered to the cache.
    struct AlbumRecord: Sendable {
        let identifier: String
        let title: String
        /// `PHCollectionType.album.rawValue`, recorded explicitly.
        ///
        /// `PHAssetCollection` does not expose its own collection type, so this is
        /// the *requested* type rather than a read-back. That is honest here only
        /// because `userAlbums` enumerates `PHAssetCollectionType.album` and
        /// nothing else — the value is stored so a future code path that does mix
        /// types cannot silently file a smart album among the user ones.
        let collectionType: Int
        /// Photos' own count for the collection. Used only to order the indexing
        /// work smallest-first; never shown to the user, because it counts the
        /// whole library including assets this instance has not scanned.
        let estimatedCount: Int
    }

    /// The **user** albums in the library, smallest first.
    ///
    /// ## Why smart albums are excluded, deliberately
    ///
    /// `PHCollectionType.smartAlbum` collections — "Recents", "Favorites",
    /// "Panoramas", "Screenshots", "Hidden", "Recently Deleted", "Media Types" —
    /// are *computed queries* over asset metadata and a rolling window, not
    /// membership a human created. Offering one as a filter next to a user album
    /// would let a computed collection behave like a real one: "Recents" would
    /// claim photos it drops tomorrow, and "Favorites" would become a second,
    /// staler source of truth for the one flag that protects photos from
    /// deletion (`delete` re-reads `isFavorite` live, the cache would not).
    ///
    /// So they are neither indexed nor offered. `PHCollectionType.album` is the
    /// only type enumerated, which is exactly the set of collections whose
    /// membership can be read *and* written by hand.
    ///
    /// `PHCollectionType.sharedAlbum` is likewise excluded: shared-library albums
    /// are not part of this user's library in the way the cache models it, and
    /// silently widening the photo pool to another person's library is not a
    /// decision this tool should make.
    func userAlbums() -> [AlbumRecord] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "estimatedAssetCount", ascending: true)]
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
        var records: [AlbumRecord] = []
        records.reserveCapacity(result.count)
        result.enumerateObjects { collection, _, _ in
            records.append(AlbumRecord(
                identifier: collection.localIdentifier,
                title: collection.localizedTitle ?? "",
                // The requested type, since `PHAssetCollection` does not report
                // its own — see `AlbumRecord.collectionType`.
                collectionType: PHAssetCollectionType.album.rawValue,
                estimatedCount: max(0, collection.estimatedAssetCount)))
        }
        return records
    }

    /// How many user albums Photos currently reports. Used by
    /// `CacheStore.albumIndexComplete` to tell "indexed everything" from
    /// "indexed whatever this cache happened to know about".
    func userAlbumCount() -> Int {
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).count
    }

    /// Enumerates one album's assets in batches, handing identifiers to
    /// `consume`.
    ///
    /// The same back-pressure argument as `enumerateImages` applies: this walks
    /// on a dedicated thread that parks while the consumer works, because the
    /// consumer is `CacheStore` on the cooperative pool and blocking that would
    /// starve it. It reuses `WalkHandoff`, which is exactly the machinery that
    /// makes a lost batch unrepresentable.
    ///
    /// An album is walked through `enumerateObjects` rather than by index for the
    /// reason documented on `enumerateImages`: `result.count` is not constant over
    /// a multi-second walk on a live library, and an index-based slice can run off
    /// the end and raise an Objective-C exception.
    func enumerateAlbumAssets(albumIdentifier: String,
                              batchSize: Int = 512,
                              consume: @Sendable ([String]) async throws -> Void) async throws {
        guard let collection = assetCollection(identifier: albumIdentifier) else { return }
        let stop = WalkCancellation()
        let handoff = WalkHandoff<String>()
        let batch = IdentifierBatch(capacity: max(1, batchSize))

        let producer = Thread {
            let options = PHFetchOptions()
            // Only stills: version 1 never scans video, and a membership row for
            // an asset with no cache row would be pruned by the next `replaceAlbumMembership`.
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            PHAsset.fetchAssets(in: collection, options: options).enumerateObjects { asset, _, stopEnumerating in
                if stop.isRequested {
                    stopEnumerating.pointee = true
                    return
                }
                batch.append(asset.localIdentifier)
                guard batch.isFull else { return }
                if !handoff.handOff(batch.take()) { stopEnumerating.pointee = true }
            }
            if !batch.isEmpty { _ = handoff.handOff(batch.take()) }
            handoff.close()
        }
        producer.name = "com.alastorid.photocleaner.album-walk"
        producer.start()

        defer {
            stop.request()
            handoff.close()
        }
        for try await batch in handoff.batches {
            try Task.checkCancellation()
            try await consume(batch)
            handoff.release()
        }
        try Task.checkCancellation()
    }

    func assetCollection(identifier: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    private func performDeletion(_ assets: [PHAsset]) async throws {
        // Single-shot, like the image request: a second resume of a checked
        // continuation traps, and a trap here would abort a deletion halfway
        // through with nothing reported. PhotoKit documents this completion
        // handler as being called once; the guard costs nothing.
        let box = ResumeBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            } completionHandler: { success, error in
                guard box.beginResume() else { return }
                if success {
                    continuation.resume()
                } else {
                    let message = error?.localizedDescription ?? "unknown PhotoKit error"
                    continuation.resume(throwing: PhotoLibraryError.deletionFailed(message))
                }
            }
        }
    }

    // MARK: - Reveal in Photos.app

    /// What handing a photo to Photos.app actually managed to do.
    ///
    /// The two cases are reported separately because the deep link is
    /// undocumented: "Photos was asked to show this photo" and "Photos is now
    /// in front of you" are different claims, and only the second one can be
    /// checked. Collapsing them would report success we cannot verify.
    struct RevealOutcome: Sendable {
        enum Mechanism: String, Sendable {
            /// Photos was handed the per-asset URL it accepts from its own widget.
            case assetLink = "asset_link"
            /// Photos was launched, but not pointed at a particular photo.
            case launchedOnly = "launched_only"
        }
        var mechanism: Mechanism
        var opened: Int
        var message: String
    }

    /// Hands one photo to Photos.app so the user can carry on there.
    ///
    /// ## The mechanism, and why this one
    ///
    /// Apple documents no way to do this. Photos has no scripting dictionary and
    /// no public URL for an individual asset, and the two obvious workarounds are
    /// both worse: composing an AppleScript for `osascript` would mean a shell, a
    /// quoting problem with a value from outside the program, and a TCC
    /// *Automation* prompt PhotoCleaner would have to ask the user to grant; and
    /// merely activating Photos would drop the user on whatever they had open
    /// last, which is not what "reveal this photo" means.
    ///
    /// What does work is a URL scheme Photos handles internally. Two forms are
    /// known, and both are built from the same primitives — a
    /// `PHAssetCollection` uuid, and the uuid at the front of a
    /// `PHAsset.localIdentifier` (`…/L0/001` trimmed to `…`):
    ///
    ///     photos://asset?identifier=<asset localIdentifier>
    ///     photos:albums?albumUuid=<library uuid>&assetUuid=<asset uuid>
    ///
    /// The first is the direct one: `photos://asset?identifier=` is present in
    /// Photos.app's own binary beside its navigation-destination code, and `photos`
    /// is a scheme Photos declares in `Info.plist`. The second is what Photos'
    /// picture widget hands to *itself* to open a photo, which is how this was
    /// found. Both are undocumented, so both are tried in that order and neither
    /// is claimed to work.
    ///
    /// ## What was verified, and what was not
    ///
    /// Verified on macOS 26.5.1 by handing each form to the installed Photos.app
    /// and reading its log: a real `localIdentifier` navigates Photos to that
    /// asset's One Up view, while an all-zero uuid changes nothing — so the
    /// navigation is caused by the identifier and not merely by activating the
    /// app. *Not* verified: which of the two forms Apple prefers, and whether
    /// either survives a future release. There is no public API to check against,
    /// so this can be reported honestly but cannot be made robust.
    ///
    /// ## Bounded on purpose
    ///
    /// One asset per call. Each reveal is a cross-process hand-off, so a
    /// selection of thousands would mean thousands of them and would hang both
    /// applications; the *caller* decides which photo that is, and this is the
    /// one the user pointed at.
    ///
    /// Nothing here writes to the library, a reveal never prompts, and no
    /// identifier is ever interpolated into a script or a command line: the URL
    /// is assembled with `URLComponents`, so the value is percent-encoded by the
    /// framework rather than by string surgery here.
    func revealInPhotos(identifier: String) async throws -> RevealOutcome {
        guard let asset = asset(identifier: identifier) else {
            throw RevealError.assetUnavailable
        }
        // Photos must exist before anything else is worth trying; otherwise the
        // honest answer is "there is no Photos on this Mac", not a launch error.
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.photosBundleIdentifier) else {
            throw RevealError.photosNotInstalled
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        let urls = Self.assetRevealURLs(for: asset)
        for url in urls {
            do {
                try await open(url, configuration: configuration)
                Log.info("handed \(identifier) to Photos as a per-asset URL")
                return RevealOutcome(mechanism: .assetLink, opened: 1,
                                     message: "Photos was asked to open this photo.")
            } catch {
                // A withdrawn scheme fails here rather than silently doing
                // nothing. Try the next form before giving up on the photo; the
                // fallback below opens Photos itself either way.
                Log.warn("Photos rejected a per-asset URL: \(error.localizedDescription)")
            }
        }
        if urls.isEmpty {
            Log.warn("no per-asset Photos URL could be built for \(identifier)")
        }

        do {
            try await launchApplication(at: application, configuration: configuration)
        } catch {
            throw RevealError.launchFailed(error.localizedDescription)
        }
        return RevealOutcome(mechanism: .launchedOnly, opened: 0,
                             message: "Photos was opened, but it could not be asked to show that "
                                    + "particular photo — find it by date in All Photos.")
    }

    /// Revealing only ever brings Photos forward; it is never asked to *control*
    /// anything on this process's behalf, so it needs no Automation permission.
    static let photosBundleIdentifier = "com.apple.Photos"

    /// The per-asset URLs, in the order they are tried.
    ///
    /// Empty when the user-library collection cannot be named, which happens only
    /// when Photos access is missing — and in that case there is no library to
    /// point at in the first place.
    static func assetRevealURLs(for asset: PHAsset) -> [URL] {
        var urls: [URL] = []
        // The direct form, and the only one that needs no album: `identifier` is
        // the full `localIdentifier`, resource path and all.
        if let direct = photosURL(host: "asset",
                                  query: [URLQueryItem(name: "identifier", value: asset.localIdentifier)]) {
            urls.append(direct)
        }
        guard let album = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil).firstObject else {
            return urls
        }
        // The widget's own form. `albums` is a path rather than a host, so it is
        // built here instead of through `photosURL`.
        var components = URLComponents()
        components.scheme = "photos"
        components.path = "albums"
        components.queryItems = [
            URLQueryItem(name: "albumUuid", value: uuid(of: album.localIdentifier)),
            URLQueryItem(name: "assetUuid", value: uuid(of: asset.localIdentifier)),
        ]
        if let widget = components.url { urls.append(widget) }
        return urls
    }

    /// `photos://<host>?<query>`, or nil if the framework refuses to build it.
    ///
    /// `URLComponents` percent-encodes the query values; nothing is concatenated
    /// into a script or a command line anywhere in this path.
    private static func photosURL(host: String, query: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = "photos"
        components.host = host
        components.queryItems = query
        return components.url
    }

    /// The uuid at the front of a `localIdentifier`, dropping the `/L0/001`
    /// resource path that follows it.
    static func uuid(of localIdentifier: String) -> String {
        String(localIdentifier.prefix(while: { $0 != "/" }))
    }

    private func open(_ url: URL, configuration: NSWorkspace.OpenConfiguration) async throws {
        let box = ResumeBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                guard box.beginResume() else { return }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func launchApplication(at url: URL,
                                   configuration: NSWorkspace.OpenConfiguration) async throws {
        let box = ResumeBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                guard box.beginResume() else { return }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

/// Why a photo could not be handed to Photos.app.
///
/// Separate from `PhotoLibraryError` because these are not PhotoKit failures:
/// they are about the other application, and every one of them has a status the
/// UI can act on. The messages name the cause rather than reporting a bare
/// error, because the deep link PhotoCleaner relies on is undocumented and a
/// future macOS is entitled to reject it.
enum RevealError: Error, CustomStringConvertible {
    /// PhotoKit no longer has this asset — deleted elsewhere, or never ours.
    case assetUnavailable
    case photosNotInstalled
    case launchFailed(String)

    var description: String {
        switch self {
        case .assetUnavailable:
            return "this photo is no longer in the Photos library"
        case .photosNotInstalled:
            return "Photos is not installed on this Mac, so there is nowhere to open the photo"
        case .launchFailed(let detail):
            return "Photos could not be opened (\(detail))"
        }
    }

    var status: Int {
        switch self {
        case .assetUnavailable: return 404
        case .photosNotInstalled, .launchFailed: return 501
        }
    }
}

/// One-shot "stop the library walk" flag, shared by the consumer side (which
/// sets it on every exit) and the producer thread (which polls it between
/// assets). The walk cannot be interrupted from inside a PhotoKit callback, so
/// the flag is checked once per asset: stopping takes at most one asset.
private final class WalkCancellation: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    var isRequested: Bool { lock.withLock { $0 } }

    func request() { lock.withLock { $0 = true } }
}

/// A strictly one-batch-in-flight hand-off between the walk thread and the
/// consumer, built so that **losing a batch is not expressible**.
///
/// This exists because of a bug that shipped in this file once. The natural way
/// to express back-pressure with `AsyncThrowingStream` is a bounded buffer and
/// to let `yield` block — it does not. `yield` on `.bufferingOldest(n)` returns
/// `.dropped(value)` the moment the buffer is full, and the value is gone. With
/// a buffer of one, a 53,177-asset scan truncated to the first 1,024, and
/// `AnalysisEngine.scan` then called `finishScan`, which deleted 51,712 live
/// cache rows. So the buffer here is unbounded — which cannot drop, only grow —
/// and the *waiting* is done by hand instead:
///
/// - `handOff` parks the producer until the consumer reports the previous batch
///   consumed. It returns `false` only when the reader is gone for good, so a
///   busy hand-off is always waited out and never discarded.
/// - `release` is called by the consumer once per batch, after `consume`.
/// - `close` unparks a producer whose reader has gone, so no thread is left
///   blocked for the life of the process.
///
/// The semaphore is the only synchronisation. Because the buffer is unbounded
/// and there is at most one batch in flight, the stream itself never holds more
/// than the single batch being handed over: the producer cannot get ahead
/// without a `release`.
private final class WalkHandoff<Element: Sendable>: @unchecked Sendable {
    /// One slot, signalled by the consumer once per batch.
    private let slots = DispatchSemaphore(value: 1)
    private let stream: AsyncThrowingStream<[Element], Error>
    private let continuation: AsyncThrowingStream<[Element], Error>.Continuation
    private let closed = OSAllocatedUnfairLock(initialState: false)

    init() {
        (stream, continuation) = AsyncThrowingStream<[Element], Error>.makeStream(
            bufferingPolicy: .unbounded)
    }

    /// The batches, in order, until the walk finishes. Awaiting this is the
    /// consumer half of the hand-off.
    var batches: AsyncThrowingStream<[Element], Error> { stream }

    /// Producer side: hands a finished batch to the consumer, waiting first until
    /// the previous one has been consumed.
    ///
    /// Returns `false` only when the walk should stop — the reader is finished —
    /// never because the hand-off was busy. `signal()` is called on every exit
    /// path, so the consumer always gets its slot back and cannot deadlock
    /// against a producer that has stopped.
    func handOff(_ batch: [Element]) -> Bool {
        while true {
            if closed.withLock({ $0 }) { return false }
            if slots.wait(timeout: .now() + 0.1) == .success { break }
            // Timed out: the consumer is either working or gone. Only the
            // latter should end the walk, so loop rather than give up.
        }
        if closed.withLock({ $0 }) {
            slots.signal()
            return false
        }
        switch continuation.yield(batch) {
        case .enqueued:
            return true
        // Unreachable while the buffer is unbounded, which never drops. Handled
        // anyway: a silently lost batch is the one outcome that must never
        // happen, so the walk stops rather than carrying on as if it were fine.
        case .dropped, .terminated:
            slots.signal()
            return false
        @unknown default:
            slots.signal()
            return false
        }
    }

    /// Consumer side: a batch has been consumed, so the walk may continue.
    func release() { slots.signal() }

    /// Idempotent. Unparks a producer waiting on `slots` and ends the walk.
    func close() {
        closed.withLock { $0 = true }
        slots.signal()
        continuation.finish()
    }
}

/// Metadata for one batch of the library walk, held by reference.
///
/// The producer's callback is a synchronous closure, so the partial batch has to
/// live in something with a stable address rather than in a local `var`. It is
/// only ever touched on the producer thread, and nothing it points at escapes
/// that thread except the arrays handed to the consumer, which are `Sendable`.
/// Metadata for one batch of the album walk, held by reference.
///
/// The same reason as `ScanRecordBatch`, with plain identifiers instead of
/// `ScanRecord`s: the PhotoKit callback is synchronous, so the partial batch
/// needs a stable address outside the closure's locals.
private final class IdentifierBatch: @unchecked Sendable {
    private let capacity: Int
    private var identifiers: [String]

    init(capacity: Int) {
        self.capacity = capacity
        self.identifiers = []
        self.identifiers.reserveCapacity(capacity)
    }

    var isFull: Bool { identifiers.count >= capacity }
    var isEmpty: Bool { identifiers.isEmpty }

    func append(_ identifier: String) { identifiers.append(identifier) }

    func take() -> [String] {
        let batch = identifiers
        identifiers = []
        identifiers.reserveCapacity(capacity)
        return batch
    }
}

private final class ScanRecordBatch: @unchecked Sendable {
    private let capacity: Int
    private var records: [ScanRecord]

    init(capacity: Int) {
        self.capacity = capacity
        self.records = []
        self.records.reserveCapacity(capacity)
    }

    var isFull: Bool { records.count >= capacity }
    var isEmpty: Bool { records.isEmpty }

    func append(_ record: ScanRecord) { records.append(record) }

    /// Hands the accumulated rows over and starts a fresh batch. Copy-on-write
    /// makes the hand-off free: the consumer gets the populated buffer and the
    /// producer keeps an empty one with its capacity reserved.
    func take() -> [ScanRecord] {
        let batch = records
        records = []
        records.reserveCapacity(capacity)
        return batch
    }
}

/// Single-shot guard shared between the image request handler and the
/// task-cancellation handler.
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var requestID: PHImageRequestID?
    private var manager: PHImageManager?

    func beginResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }

    func set(requestID: PHImageRequestID, manager: PHImageManager) {
        lock.lock()
        let alreadyCancelled = resumed
        self.requestID = requestID
        self.manager = manager
        lock.unlock()
        if alreadyCancelled { manager.cancelImageRequest(requestID) }
    }

    func cancel() {
        lock.lock()
        let id = requestID
        let manager = manager
        lock.unlock()
        if let id, let manager { manager.cancelImageRequest(id) }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        var result: [[Element]] = []
        result.reserveCapacity((count + size - 1) / size)
        var index = 0
        while index < count {
            result.append(Array(self[index..<Swift.min(index + size, count)]))
            index += size
        }
        return result
    }
}
