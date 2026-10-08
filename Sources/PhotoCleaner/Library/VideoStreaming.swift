import AVFoundation
import CoreMedia
import Foundation
import os
import Photos

/// Fragmented MP4 (fMP4) streaming for videos.
///
/// Instead of exporting the entire clip to disk first (which takes minutes for GB files
/// and consumes GBs of space), this reads samples from the `AVAsset` via `AVAssetReader`
/// and writes them as fMP4 fragments via `AVAssetWriter` directly to the HTTP response.
///
/// ## fMP4 Structure
///
/// - **Init Segment** (sent first): `ftyp` + `moov` with track info, no media data
/// - **Media Segments** (sent as fragments): `moof` + `mdat` pairs, each containing
///   a short run of samples (default ~2 seconds per fragment)
final class VideoStreamer: @unchecked Sendable {
    private let log = OSLog(subsystem: "com.alastorid.photocleaner", category: "VideoStreaming")

    /// Target duration per fragment, in seconds.
    ///
    /// Shorter = lower latency to first frame, more overhead.
    /// 2 seconds matches HLS/DASH typical segment duration.
    private static let fragmentDuration: Double = 2.0

    /// Stream a video as fMP4, calling `write` for each fragment produced.
    ///
    /// - Parameters:
    ///   - identifier: Photos asset identifier
    ///   - allowNetwork: Whether to download from iCloud
    ///   - startTime: Presentation time to start from (for seeking). `nil` = beginning.
    ///   - write: Called with each fragment's bytes. Return `false` to cancel.
    /// - Returns: Total duration of the asset, or `nil` if unknown.
    func stream(identifier: String,
                allowNetwork: Bool,
                startTime: CMTime? = nil,
                write: @escaping (Data) -> Bool) async throws -> Double? {
        let asset = try await videoAsset(identifier: identifier, allowNetwork: allowNetwork)

        // Load tracks using modern async API
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !videoTracks.isEmpty else { throw PhotoLibraryError.imageUnavailable }

        let videoTrack = videoTracks[0]

        // Load track properties (loaded to ensure format is available for passthrough)
        _ = try await videoTrack.load(.naturalSize)
        _ = try await videoTrack.load(.nominalFrameRate)
        _ = try await videoTrack.load(.formatDescriptions)

        // We'll write to an in-memory buffer that we drain via the write callback.
        let buffer = StreamingBuffer()
        let writerDelegate = StreamingWriterDelegate(buffer: buffer)

        // Configure AVAssetWriter for fMP4
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
        writer.delegate = writerDelegate
        writer.movieFragmentInterval = CMTime(seconds: Self.fragmentDuration, preferredTimescale: 600)

        // Video track settings - use passthrough (keep original codec)
        // For passthrough, use nil outputSettings. The writer infers format from sample buffers.
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        writerInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(writerInput) else { throw PhotoLibraryError.imageUnavailable }
        writer.add(writerInput)

        // Audio track (optional)
        var audioInput: AVAssetWriterInput?
        if let audioTrack = audioTracks.first {
            let audioFormatDescriptions = try await audioTrack.load(.formatDescriptions)
            var sampleRate: Double = 44100
            if let fmtDesc = audioFormatDescriptions.first {
                let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)
                if let basicDesc = basicDesc {
                    sampleRate = basicDesc.pointee.mSampleRate
                }
            }

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
            ]
            audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audioInput?.expectsMediaDataInRealTime = false
            if writer.canAdd(audioInput!) { writer.add(audioInput!) }
        }

        // Reader for the asset
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw PhotoLibraryError.imageUnavailable }
        reader.add(readerOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTracks.first {
            audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            audioOutput?.alwaysCopiesSampleData = false
            if reader.canAdd(audioOutput!) { reader.add(audioOutput!) }
        }

        // Seek to start time if provided
        if let startTime = startTime {
            reader.timeRange = CMTimeRange(start: startTime, duration: .indefinite)
        }

        // Start writing
        guard writer.startWriting() else {
            throw PhotoLibraryError.imageRequestFailed(writer.error?.localizedDescription ?? "writer failed to start")
        }
        writer.startSession(atSourceTime: reader.timeRange.start)
        reader.startReading()

        // Write init segment first (ftyp + moov)
        let initData = try await writeInitSegment(writer: writer, buffer: buffer)
        guard write(initData) else { throw CancellationError() }

        // Stream fragments
        while reader.status == .reading {
            // Process video samples
            if writerInput.isReadyForMoreMediaData {
                while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                    if !writerInput.append(sampleBuffer) {
                        if let error = writer.error { throw PhotoLibraryError.imageRequestFailed(error.localizedDescription) }
                        throw PhotoLibraryError.imageUnavailable
                    }

                    // Drain buffer
                    while let data = buffer.pop(), !data.isEmpty {
                        guard write(data) else { throw CancellationError() }
                    }
                }
            }

            // Process audio samples
            if let audioInput = audioInput, let audioOutput = audioOutput, audioInput.isReadyForMoreMediaData {
                while let sampleBuffer = audioOutput.copyNextSampleBuffer() {
                    if !audioInput.append(sampleBuffer) {
                        if let error = writer.error { throw PhotoLibraryError.imageRequestFailed(error.localizedDescription) }
                        throw PhotoLibraryError.imageUnavailable
                    }
                    while let data = buffer.pop(), !data.isEmpty {
                        guard write(data) else { throw CancellationError() }
                    }
                }
            }

            // Check for end
            if reader.status == .completed {
                break
            }

            // Brief yield to avoid busy loop
            try await Task.sleep(nanoseconds: 1_000_000)  // 1ms
        }

        // Finish
        writerInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [weak buffer] in
            buffer?.finish()
        }

        // Drain remaining
        while let data = buffer.pop(), !data.isEmpty {
            guard write(data) else { throw CancellationError() }
        }

        if reader.status == .failed, let error = reader.error {
            throw PhotoLibraryError.imageRequestFailed(error.localizedDescription)
        }
        if writer.status == .failed, let error = writer.error {
            throw PhotoLibraryError.imageRequestFailed(error.localizedDescription)
        }

        let duration = try await asset.load(.duration)
        return duration.seconds
    }

    /// Writes the fMP4 init segment (ftyp + moov) by triggering the writer's header generation.
    private func writeInitSegment(writer: AVAssetWriter, buffer: StreamingBuffer) async throws -> Data {
        // The init segment is written when we first start the session.
        // We need to capture the initial bytes written to the buffer.
        var attempts = 0
        while attempts < 100 {
            if let data = buffer.pop(), !data.isEmpty {
                return data
            }
            try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
            attempts += 1
        }
        throw PhotoLibraryError.imageUnavailable
    }

    // Reuse the existing videoAsset method logic
    private func videoAsset(identifier: String, allowNetwork: Bool) async throws -> AVAsset {
        guard let asset = PhotoLibrary.shared.asset(identifier: identifier) else {
            throw PhotoLibraryError.assetNotFound
        }
        guard asset.mediaType == .video else { throw PhotoLibraryError.assetNotFound }

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
}

/// Thread-safe buffer for streaming writer output.
private final class StreamingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var finished = false
    private var waiters: [CheckedContinuation<Data?, Never>] = []

    func append(_ data: Data) {
        lock.lock()
        chunks.append(data)
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: data)
        }
        lock.unlock()
    }

    func pop() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return chunks.isEmpty ? nil : chunks.removeFirst()
    }

    func finish() {
        lock.lock()
        finished = true
        for waiter in waiters {
            waiter.resume(returning: nil)
        }
        waiters.removeAll()
        lock.unlock()
    }

    func waitForData() async -> Data? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let data = chunks.isEmpty ? nil : chunks.removeFirst() {
                lock.unlock()
                continuation.resume(returning: data)
            } else if finished {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Delegate to capture AVAssetWriter output as it's produced.
private final class StreamingWriterDelegate: NSObject, AVAssetWriterDelegate {
    let buffer: StreamingBuffer

    init(buffer: StreamingBuffer) {
        self.buffer = buffer
    }

    func assetWriter(_ writer: AVAssetWriter, didWrite mediaData: Data, for input: AVAssetWriterInput) {
        buffer.append(mediaData)
    }
}

/// Carries a value PhotoKit handed back across a task boundary.
private struct HandedOff<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Single-shot resume guard for one `requestAVAsset`.
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