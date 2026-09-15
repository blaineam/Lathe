import AVFoundation
import Foundation
import LatheCore

/// Joins a video-only file and an audio-only file into one playable file,
/// **without re-encoding either**.
///
/// ## Why this type exists
///
/// `yt-dlp` solves this problem by shelling out to `ffmpeg`. PEP 730 removes
/// process spawning on iOS, so that call cannot work here — and the cheap
/// answer, restricting format selection to renditions that are already muxed,
/// costs more than it looks. See ``FormatSelector`` for the measurement: on the
/// largest site in the extractor list it is the difference between 360p and 4K.
///
/// So the merge is done in-process with `AVAssetWriter`. The streams were
/// encoded by the origin server and are already in codecs the container
/// accepts; there is nothing to gain by decoding and re-encoding them, and a
/// generation of quality to lose. Every sample is therefore **passed through**:
/// `AVAssetReaderTrackOutput` with `outputSettings: nil` hands back the
/// original `CMSampleBuffer`s, and `AVAssetWriterInput` with
/// `outputSettings: nil` writes them unchanged.
///
/// ## The hazard this is written around
///
/// Driving a two-input `AVAssetWriter` by polling `isReadyForMoreMediaData` in
/// a loop **deadlocks**, silently: one input goes not-ready part way through
/// and never comes back, the writer's status stays `.writing`, and no error is
/// ever reported. The job simply stops.
///
/// The correct shape is one `requestMediaDataWhenReady(on:using:)` pump per
/// input, letting the writer schedule both and do its own interleaving. That is
/// what ``WriterPump`` is, and it is the same machinery — and the same hazard —
/// that `LatheVideo`'s transcoder and the test-support fixture writer carry.
/// Three copies of a hazard this quiet is not duplication; it is the number of
/// places somebody could otherwise reintroduce it.
///
/// ## Partial files
///
/// Nothing is ever written to `destination` until the mux has finished. The
/// writer works in a sibling temporary file and the result is moved into place
/// atomically, so a cancelled or failed mux leaves the destination exactly as
/// it found it — absent, usually.
public enum StreamMuxer {

    // MARK: - Container compatibility

    /// Video codecs an MPEG-4 container will hold, by the four-character prefix
    /// `yt-dlp` reports in `vcodec`.
    ///
    /// Deliberately conservative. `AVFoundation` will put H.264, HEVC and AV1
    /// into an `.mp4`; it will not take VP8, VP9 or Theora, and the failure
    /// when it is asked to is an opaque `-11800` at `startWriting` time rather
    /// than anything that names the codec. Checking first is what turns that
    /// into ``MediaFetchError/muxingFailed(stage:reason:)`` with the codec in
    /// it.
    public static let muxableVideoCodecPrefixes = ["avc1", "avc3", "h264", "hev1", "hvc1", "hevc", "av01"]

    /// Audio codecs an MPEG-4 container will hold.
    ///
    /// Opus is absent on purpose. It has an MPEG-4 encapsulation and
    /// `AVFoundation`'s support for writing it is not dependable across the
    /// versions this package targets — and on the sites that publish Opus, an
    /// AAC rendition is published beside it, so declining costs nothing.
    public static let muxableAudioCodecPrefixes = ["mp4a", "aac", "ac-3", "ec-3", "alac"]

    /// Whether a rendition's video track can be written into an `.mp4`.
    ///
    /// An *unknown* codec answers `true`. The extractor not saying what the
    /// codec is does not mean it is unsupported, and refusing on missing
    /// metadata would rule out a great many perfectly muxable renditions.
    public static func canMuxVideo(_ format: MediaFormat) -> Bool {
        guard let codec = format.videoCodec?.lowercased() else { return true }
        return muxableVideoCodecPrefixes.contains { codec.hasPrefix($0) }
    }

    /// Whether a rendition's audio track can be written into an `.mp4`.
    public static func canMuxAudio(_ format: MediaFormat) -> Bool {
        guard let codec = format.audioCodec?.lowercased() else { return true }
        return muxableAudioCodecPrefixes.contains { codec.hasPrefix($0) }
    }

    // MARK: - The mux

    /// What a completed mux produced.
    public struct Result: Sendable, Equatable {
        public let url: URL
        public let duration: TimeInterval
        public let byteCount: Int64
        /// The video codec that was written, as a four-character code.
        public let videoCodec: String?
        /// The audio codec that was written.
        public let audioCodec: String?
    }

    /// Writes the video track of `video` and the audio track of `audio` into
    /// one file at `destination`.
    ///
    /// - Parameters:
    ///   - video: a file with at least one video track. Any audio it carries is
    ///     ignored — the audio comes from the other file, which is the point.
    ///   - audio: a file with at least one audio track.
    ///   - destination: where the result goes. Replaced if it exists, but only
    ///     once the mux has succeeded.
    ///   - progress: reported against the video track's duration, under the
    ///     stage name `"mux"`. Cancellation is honoured at every sample.
    /// - Throws: ``MediaFetchError/muxingFailed(stage:reason:)``, or
    ///   ``LatheError/cancelled(atUnit:)`` when the progress handle or the
    ///   enclosing task was cancelled.
    public static func mux(
        video: URL,
        audio: URL,
        to destination: URL,
        progress: ProgressHandle = .ignoring()
    ) async throws -> Result {

        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)

        guard let videoTrack = try await firstTrack(of: videoAsset, mediaType: .video) else {
            throw MediaFetchError.muxingFailed(
                stage: "read", reason: "the downloaded video file has no video track")
        }
        guard let audioTrack = try await firstTrack(of: audioAsset, mediaType: .audio) else {
            throw MediaFetchError.muxingFailed(
                stage: "read", reason: "the downloaded audio file has no audio track")
        }

        let videoFormat = try await videoTrack.load(.formatDescriptions).first
        let audioFormat = try await audioTrack.load(.formatDescriptions).first

        // Check each input's sample timing against what its own container
        // says, because for YouTube's fragmented MP4 they disagree by a factor
        // of two. See `TimingCorrection` and `MP4MovieHeader`.
        let videoCorrection = await TimingCorrection(for: videoTrack, file: video)
        let audioCorrection = await TimingCorrection(for: audioTrack, file: audio)
        let videoDuration = videoCorrection.corrected(
            try await videoAsset.load(.duration))

        // The temporary file is a sibling of the destination rather than in the
        // system temporary directory: a move within one volume is atomic and a
        // move across volumes is a copy, and a 4K download is not a thing to
        // copy twice.
        let workingURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".lathe-mux-\(UUID().uuidString).mp4")

        func discardWorkingFile() { try? FileManager.default.removeItem(at: workingURL) }

        do {
            try await write(
                videoTrack: videoTrack,
                videoAsset: videoAsset,
                videoFormat: videoFormat,
                audioTrack: audioTrack,
                audioAsset: audioAsset,
                audioFormat: audioFormat,
                to: workingURL,
                totalDuration: videoDuration,
                videoCorrection: videoCorrection,
                audioCorrection: audioCorrection,
                progress: progress
            )
        } catch {
            discardWorkingFile()
            throw error
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: workingURL)
            } else {
                try FileManager.default.moveItem(at: workingURL, to: destination)
            }
        } catch {
            discardWorkingFile()
            throw MediaFetchError.muxingFailed(
                stage: "publish",
                reason: "the muxed file could not be moved into place: \((error as NSError).localizedDescription)")
        }

        let byteCount = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
        let written = AVURLAsset(url: destination)
        let writtenDuration = (try? await written.load(.duration)) ?? videoDuration

        return Result(
            url: destination,
            duration: CMTimeGetSeconds(writtenDuration),
            byteCount: byteCount ?? 0,
            videoCodec: videoFormat.map { fourCharacterCode(CMFormatDescriptionGetMediaSubType($0)) },
            audioCodec: audioFormat.map { fourCharacterCode(CMFormatDescriptionGetMediaSubType($0)) }
        )
    }

    // MARK: - Writing

    private static func write(
        videoTrack: AVAssetTrack,
        videoAsset: AVURLAsset,
        videoFormat: CMFormatDescription?,
        audioTrack: AVAssetTrack,
        audioAsset: AVURLAsset,
        audioFormat: CMFormatDescription?,
        to url: URL,
        totalDuration: CMTime,
        videoCorrection: TimingCorrection,
        audioCorrection: TimingCorrection,
        progress: ProgressHandle
    ) async throws {

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw MediaFetchError.muxingFailed(
                stage: "open", reason: (error as NSError).localizedDescription)
        }

        // `outputSettings: nil` is the passthrough contract on both sides: the
        // reader hands back the encoded samples and the writer takes them
        // unchanged. Anything else here would decode and re-encode a stream
        // that was downloaded thirty seconds ago, which costs time, battery and
        // a generation of quality in exchange for nothing at all.
        let videoInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        let audioInput = AVAssetWriterInput(
            mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
        videoInput.expectsMediaDataInRealTime = false
        audioInput.expectsMediaDataInRealTime = false

        // Carry the source's rotation. YouTube and most of the rest publish
        // upright video, but a phone-shot vertical clip records its orientation
        // in the track transform and dropping it produces a sideways file.
        if let transform = try? await videoTrack.load(.preferredTransform) {
            videoInput.transform = transform
        }

        guard writer.canAdd(videoInput) else {
            throw MediaFetchError.muxingFailed(
                stage: "configure",
                reason: "an MPEG-4 file cannot hold this video track"
                    + (videoFormat.map { " (\(fourCharacterCode(CMFormatDescriptionGetMediaSubType($0))))" } ?? ""))
        }
        writer.add(videoInput)

        guard writer.canAdd(audioInput) else {
            throw MediaFetchError.muxingFailed(
                stage: "configure",
                reason: "an MPEG-4 file cannot hold this audio track"
                    + (audioFormat.map { " (\(fourCharacterCode(CMFormatDescriptionGetMediaSubType($0))))" } ?? ""))
        }
        writer.add(audioInput)

        let videoReader = try makeReader(asset: videoAsset, track: videoTrack, label: "video")
        let audioReader = try makeReader(asset: audioAsset, track: audioTrack, label: "audio")
        let videoOutput = videoReader.outputs[0]
        let audioOutput = audioReader.outputs[0]

        guard writer.startWriting() else {
            throw MediaFetchError.muxingFailed(
                stage: "start",
                reason: writer.error.map { ($0 as NSError).localizedDescription } ?? "startWriting returned false")
        }
        writer.startSession(atSourceTime: .zero)
        videoReader.startReading()
        audioReader.startReading()

        let totalSeconds = CMTimeGetSeconds(totalDuration)
        let clock = MuxClock()

        func makeStep(
            output: AVAssetReaderOutput,
            reader: AVAssetReader,
            input: AVAssetWriterInput,
            isVideo: Bool,
            correction: TimingCorrection
        ) -> () throws -> Bool {
            {
                guard let raw = output.copyNextSampleBuffer() else {
                    // A reader that stopped for a reason other than running out
                    // of samples has to be reported, or a truncated download
                    // becomes a short file that looks fine.
                    if reader.status == .failed {
                        throw MediaFetchError.muxingFailed(
                            stage: isVideo ? "read video" : "read audio",
                            reason: reader.error.map { ($0 as NSError).localizedDescription } ?? "the reader failed")
                    }
                    return false
                }
                let sample: CMSampleBuffer
                do {
                    sample = try correction.apply(to: raw)
                } catch {
                    throw MediaFetchError.muxingFailed(
                        stage: isVideo ? "retime video" : "retime audio",
                        reason: (error as NSError).localizedDescription)
                }
                guard input.append(sample) else {
                    throw MediaFetchError.muxingFailed(
                        stage: isVideo ? "write video" : "write audio",
                        reason: "the writer rejected a sample")
                }

                let end = CMTimeAdd(
                    CMSampleBufferGetPresentationTimeStamp(sample),
                    CMSampleBufferGetDuration(sample))
                clock.observe(end: end)

                // Progress is the video track's timeline. The audio pump
                // deliberately reports nothing: two pumps reporting into one
                // handle produce a bar that jumps backwards, and the video is
                // the longer job in every case that matters.
                //
                // The *furthest* timestamp seen, not this sample's — samples
                // arrive in decode order, and any H.264 stream with B-frames
                // therefore hands back presentation timestamps that go
                // backwards several times a second. Reporting those directly
                // makes a progress bar that visibly stutters in reverse.
                if isVideo {
                    let seconds = CMTimeGetSeconds(clock.endTime ?? end)
                    guard progress.report(
                        LatheProgress(
                            fraction: totalSeconds > 0 ? seconds / totalSeconds : nil,
                            stage: "mux",
                            unitIndex: UInt64(max(0, seconds)),
                            unitCount: UInt64(max(0, totalSeconds))))
                    else {
                        throw LatheError.cancelled(atUnit: UInt64(max(0, seconds)))
                    }
                } else {
                    try progress.checkCancellation()
                }
                return true
            }
        }

        // The pumps are built out here, not inside the task group. A task
        // group's body closure is `@Sendable` and `AVAssetReader`,
        // `AVAssetReaderOutput` and `AVAssetWriterInput` are none of them
        // `Sendable`; the pump is the `@unchecked Sendable` box that owns them,
        // so only the box crosses into the child tasks.
        let videoPump = WriterPump(
            input: videoInput, label: "mux.video",
            step: makeStep(output: videoOutput, reader: videoReader, input: videoInput,
                           isVideo: true, correction: videoCorrection))
        let audioPump = WriterPump(
            input: audioInput, label: "mux.audio",
            step: makeStep(output: audioOutput, reader: audioReader, input: audioInput,
                           isVideo: false, correction: audioCorrection))

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await videoPump.run() }
                group.addTask { try await audioPump.run() }
                // `waitForAll` rather than draining: the first failure must
                // cancel the other pump, and a pump left waiting on a writer
                // that is no longer scheduling anything waits forever.
                try await group.waitForAll()
            }
        } catch {
            // The readers and the writer are torn down before the error leaves,
            // so nothing is left holding the working file when the caller
            // deletes it. The error itself is rethrown unchanged: it is already
            // a `MediaFetchError` or a `LatheError.cancelled`, both of which
            // carry more than any re-wrapping would.
            videoReader.cancelReading()
            audioReader.cancelReading()
            writer.cancelWriting()
            throw error
        }

        if let end = clock.endTime {
            writer.endSession(atSourceTime: end)
        }
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw MediaFetchError.muxingFailed(
                stage: "finish",
                reason: writer.error.map { ($0 as NSError).localizedDescription }
                    ?? "the writer ended in state \(writer.status.rawValue)")
        }
    }

    private static func makeReader(
        asset: AVURLAsset, track: AVAssetTrack, label: String
    ) throws -> AVAssetReader {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MediaFetchError.muxingFailed(
                stage: "open \(label)", reason: (error as NSError).localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MediaFetchError.muxingFailed(
                stage: "open \(label)", reason: "the \(label) track cannot be read in passthrough mode")
        }
        reader.add(output)
        return reader
    }

    private static func firstTrack(
        of asset: AVURLAsset, mediaType: AVMediaType
    ) async throws -> AVAssetTrack? {
        do {
            return try await asset.loadTracks(withMediaType: mediaType).first
        } catch {
            throw MediaFetchError.muxingFailed(
                stage: "read",
                reason: "the file could not be opened as media: \((error as NSError).localizedDescription)")
        }
    }

    /// `'avc1'` from the `FourCharCode` a format description reports.
    static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - The end of the timeline

/// The latest sample end seen on either input, which is where the writing
/// session is ended.
///
/// Taken from what was actually written rather than from the asset's declared
/// duration: the two disagree whenever a download was truncated, and ending the
/// session past the last sample produces a file whose final second is silence
/// and a frozen frame.
private final class MuxClock: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CMTime = .invalid

    var endTime: CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return latest.isValid ? latest : nil
    }

    func observe(end: CMTime) {
        guard end.isValid else { return }
        lock.lock()
        if !latest.isValid || end > latest { latest = end }
        lock.unlock()
    }
}

// MARK: - The pump

/// Feeds one `AVAssetWriterInput` until its source is exhausted.
///
/// See the discussion on ``StreamMuxer``: this is the shape that does not
/// deadlock, and the polling loop it replaces fails completely silently.
private final class WriterPump: @unchecked Sendable {

    private let input: AVAssetWriterInput
    private let label: String
    /// One step. Returns `false` when the source is exhausted. Called only on
    /// this pump's own serial queue.
    private let step: () throws -> Bool

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var settled = false
    private var stopped = false

    init(input: AVAssetWriterInput, label: String, step: @escaping () throws -> Bool) {
        self.input = input
        self.label = label
        self.step = step
    }

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()

                let queue = DispatchQueue(label: "dev.lathe.fetch.\(label)")
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    do {
                        while !isStopped, input.isReadyForMoreMediaData {
                            if try step() == false {
                                input.markAsFinished()
                                settle(nil)
                                return
                            }
                        }
                    } catch {
                        input.markAsFinished()
                        settle(error)
                    }
                }
            }
        } onCancel: {
            lock.lock()
            stopped = true
            lock.unlock()
            settle(CancellationError())
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Resumes exactly once. The callback fires again after `markAsFinished()`,
    /// and resuming a continuation twice traps.
    private func settle(_ error: (any Error)?) {
        lock.lock()
        guard !settled, let continuation else { lock.unlock(); return }
        settled = true
        self.continuation = nil
        lock.unlock()
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
