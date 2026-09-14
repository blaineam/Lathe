import Accelerate
import AVFoundation
import CoreMedia
import Foundation
import LatheCore

/// The result of measuring a file's mean level.
///
/// An enum rather than a `Float` because the three outcomes are genuinely
/// different and a single number can only express one of them:
///
/// - ``noAudioTrack`` — the file has no audio at all. Not an error: a video
///   shot with the microphone disabled is a perfectly valid file, and a caller
///   deciding whether to re-encode audio needs to know it has nothing to do
///   rather than receive a very small number.
/// - ``digitalSilence`` — there is a track and every sample in it is exactly
///   zero. Its true mean level is −∞ dBFS, which no `Float` represents usefully.
///   Synthesised or muted audio looks like this; a real recording in a quiet
///   room does not, because a microphone's noise floor sits somewhere around
///   −60 to −80 dBFS.
/// - ``decibels(_:)`` — an actual measurement.
///
/// Collapsing the first two into a number is exactly how "this file has no
/// sound" and "this file's sound is quiet" get confused downstream.
public enum MeanVolume: Sendable, Equatable {
    case noAudioTrack
    case digitalSilence
    case decibels(Float)

    /// The value ffmpeg's `volumedetect` filter prints for digitally silent
    /// input. It reports a floor rather than `-inf`, because its statistics run
    /// over a 16-bit histogram that bottoms out one quantum above zero.
    ///
    /// Exposed as a named constant so that a caller who needs one number can
    /// take ``decibelsOrFloor`` and stay bug-compatible with thresholds tuned
    /// against that tool, instead of each call site inventing its own sentinel.
    public static let digitalSilenceFloorDB: Float = -91

    /// The measurement, or `nil` when there is nothing to measure.
    public var decibels: Float? {
        if case let .decibels(value) = self { return value }
        return nil
    }

    /// The measurement, with ``digitalSilenceFloorDB`` standing in for silence
    /// and for the absent track. For callers that must have a `Float`.
    public var decibelsOrFloor: Float {
        decibels ?? Self.digitalSilenceFloorDB
    }

    public var hasAudioTrack: Bool {
        self != .noAudioTrack
    }
}

/// Measures how loud a file's audio actually is.
///
/// Two questions, two methods, and the reason they are not one method is the
/// most useful thing in this file.
///
/// ``meanVolumeDB(url:progress:)`` answers *"what is the average level"*.
/// ``hasAudibleAudio(url:thresholds:)`` answers *"will a listener hear
/// anything"*. Those sound like the same question and are not, because **mean
/// volume has a false-negative cliff on sparse audio**: it divides the total
/// energy by the total duration, so silence dilutes it without limit. A
/// ten-minute clip containing two seconds of clear speech and 598 seconds of
/// silence measures about −45 dBFS and is indistinguishable, by that number
/// alone, from a file with nothing in it. That is not a corner case — it is the
/// shape of an ordinary phone video with one spoken sentence in it, and a "is
/// this silent" check built on mean volume will throw away its audio.
///
/// So ``hasAudibleAudio(url:thresholds:)`` does not average anything. It walks
/// short windows and stops at the first one that clears the threshold, which
/// makes it both correct on sparse audio *and* much cheaper on ordinary audio:
/// any file that does have sound near its start returns after decoding a
/// fraction of a second. Only a genuinely silent file pays for a full scan —
/// and it has to, because sound can begin at 9:58.
///
/// ``meanVolumeDB(url:progress:)`` is kept because it is what the familiar
/// command-line filter reports, and existing thresholds are calibrated against
/// it. Use it to reproduce a number. Do not use it to make a decision.
public struct LoudnessProbe: Sendable {

    public init() {}

    // MARK: - Mean volume

    /// The mean level over the whole file, in dBFS.
    ///
    /// Computed as `10 · log₁₀(Σ(s²) / N)` over every sample of every channel —
    /// the same statistic, over the same samples, that `volumedetect` reports,
    /// so a caller replacing that filter gets the same number to compare against
    /// its existing thresholds. (It is the mean *power* expressed in dB, which
    /// is why the multiplier is 10 and not 20.)
    ///
    /// **Read the type documentation before using this to decide anything.**
    ///
    /// - Throws: ``LatheError/readFailed(path:reason:)`` or
    ///   ``LatheError/invalidInput(reason:)`` for a file that cannot be opened;
    ///   ``LatheError/cancelled(atUnit:)`` if the enclosing `Task` is cancelled.
    public func meanVolumeDB(
        url: URL,
        progress: ProgressHandle = .ignoring()
    ) async throws -> MeanVolume {
        guard let session = try await Self.makeReader(url: url) else { return .noAudioTrack }

        let scan = try await Self.scan(session, mode: .whole, progress: progress)

        guard scan.sampleCount > 0 else { return .digitalSilence }
        guard scan.sumOfSquares > 0 else { return .digitalSilence }

        let mean = scan.sumOfSquares / Double(scan.sampleCount)
        return .decibels(Float(10 * log10(mean)))
    }

    // MARK: - Audibility

    /// Whether any short window of this file is loud enough to hear. Returns as
    /// soon as one is.
    ///
    /// A window must clear **both** thresholds: a peak above
    /// ``AudibilityThresholds/peakDBFS`` and a window RMS above
    /// ``AudibilityThresholds/shortTermRMSDBFS``. The second is what stops a
    /// single-sample click — a decoder artefact, a splice — from being reported
    /// as audio.
    ///
    /// `false` for a file with no audio track. The boolean answers "will a
    /// listener hear anything", and for that question no track and a silent
    /// track have the same answer; ``meanVolumeDB(url:progress:)`` is where the
    /// two are told apart.
    public func hasAudibleAudio(
        url: URL,
        thresholds: AudibilityThresholds = .default
    ) async throws -> Bool {
        try await audibilityScan(url: url, thresholds: thresholds).isAudible
    }

    /// ``hasAudibleAudio(url:thresholds:)`` with the scan's own accounting
    /// attached.
    ///
    /// `framesExamined` against `framesAvailable` is how the early exit is
    /// verified rather than asserted — a regression that removed it would still
    /// return the right boolean, so the boolean cannot be the test.
    struct AudibilityScan: Sendable, Equatable {
        var isAudible: Bool
        var hasAudioTrack: Bool
        var loudestWindowPeakDBFS: Float
        var framesExamined: UInt64
        var framesAvailable: UInt64
    }

    func audibilityScan(
        url: URL,
        thresholds: AudibilityThresholds = .default
    ) async throws -> AudibilityScan {
        guard let session = try await Self.makeReader(url: url) else {
            return AudibilityScan(
                isAudible: false, hasAudioTrack: false,
                loudestWindowPeakDBFS: MeanVolume.digitalSilenceFloorDB,
                framesExamined: 0, framesAvailable: 0
            )
        }

        let scan = try await Self.scan(
            session, mode: .stopWhenAudible(thresholds), progress: .ignoring()
        )
        return AudibilityScan(
            isAudible: scan.foundAudibleWindow,
            hasAudioTrack: true,
            loudestWindowPeakDBFS: Self.decibels(fromAmplitude: scan.peak),
            framesExamined: scan.sampleCount / UInt64(max(1, session.channelCount)),
            framesAvailable: UInt64((session.duration * session.sampleRate).rounded())
        )
    }

    // MARK: - Reader

    /// An opened reader plus the facts needed to interpret its samples.
    ///
    /// `@unchecked Sendable` and a one-way handoff: `AVAssetReader` is not
    /// `Sendable` and is not thread-safe, but it *is* safe to use from one
    /// thread at a time. This is constructed on the calling thread and then
    /// handed to a worker thread that becomes its sole owner — nothing here
    /// touches it again. The alternative is doing blocking reads on a
    /// cooperative-pool thread, which is the thing `LatheWork` exists to
    /// prevent.
    private struct ReaderSession: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let sampleRate: Double
        let channelCount: Int
        let duration: TimeInterval
    }

    /// - Returns: `nil` when the file has no audio track. Throws only for files
    ///   that cannot be opened at all.
    private static func makeReader(url: URL) async throws -> ReaderSession? {
        guard url.isFileURL else {
            throw LatheError.invalidInput(reason: "LoudnessProbe reads local files only")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "not readable")
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw LatheError.invalidInput(
                reason: "\(url.lastPathComponent) is not a media file AVFoundation can open"
            )
        }
        guard let track = tracks.first else { return nil }

        let duration = (try? await asset.load(.duration)).map {
            $0.isNumeric ? max(0, $0.seconds) : 0
        } ?? 0

        var sampleRate: Double = 0
        var channelCount = 1
        if let description = try await track.load(.formatDescriptions).first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            sampleRate = asbd.mSampleRate
            channelCount = max(1, Int(asbd.mChannelsPerFrame))
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw LatheError.wrapping(error)
        }

        // Decode to interleaved 32-bit float, which is what vDSP wants and what
        // every codec converts to anyway. Channels are *not* mixed down: a
        // channel count is applied to the sample total instead, so the mean
        // matches the per-sample mean the reference filter computes.
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        output.alwaysCopiesSampleData = false   // read-only pass; the copy is waste
        guard reader.canAdd(output) else {
            throw LatheError.invalidInput(
                reason: "\(url.lastPathComponent)'s audio track cannot be decoded to PCM"
            )
        }
        reader.add(output)

        return ReaderSession(
            reader: reader,
            output: output,
            sampleRate: sampleRate > 0 ? sampleRate : 44_100,
            channelCount: channelCount,
            duration: duration
        )
    }

    // MARK: - The scan

    private enum ScanMode: Sendable {
        /// Read everything and accumulate.
        case whole
        /// Stop at the first window that clears both thresholds.
        case stopWhenAudible(AudibilityThresholds)
    }

    private struct ScanResult: Sendable {
        var sumOfSquares: Double = 0
        var sampleCount: UInt64 = 0
        var peak: Float = 0
        var foundAudibleWindow = false
    }

    /// Runs the blocking decode on a dedicated worker thread.
    ///
    /// `AVAssetReaderOutput.copyNextSampleBuffer()` blocks, and blocking a
    /// cooperative-pool thread starves Swift concurrency. ``LatheWork`` already
    /// owns that rule, including wiring `Task` cancellation into the handle, so
    /// this goes through it rather than reimplementing it.
    private static func scan(
        _ session: ReaderSession,
        mode: ScanMode,
        progress: ProgressHandle
    ) async throws -> ScanResult {
        try await LatheWork.run(with: progress) { handle in
            try scanSynchronously(session, mode: mode, progress: handle)
        }
    }

    private static func scanSynchronously(
        _ session: ReaderSession,
        mode: ScanMode,
        progress: ProgressHandle
    ) throws -> ScanResult {
        guard session.reader.startReading() else {
            throw LatheError.wrapping(
                session.reader.error ?? LatheError.underlying("AVAssetReader would not start")
            )
        }
        defer { session.reader.cancelReading() }

        var result = ScanResult()

        // 400 ms, the short-term window EBU R 128 uses. Long enough that a
        // one-sample click cannot carry a window's RMS on its own, short enough
        // that a single spoken word fills most of one.
        let windowFrames = max(1, Int(session.sampleRate * 0.4))
        let windowValues = windowFrames * session.channelCount
        var windowSum: Double = 0
        var windowCount = 0
        var windowPeak: Float = 0

        var thresholds: AudibilityThresholds?
        if case let .stopWhenAudible(values) = mode { thresholds = values }

        let totalFrames = max(1.0, session.duration * session.sampleRate)
        var reportedUnit: UInt64 = 0

        func closeWindow() {
            guard windowCount > 0, let thresholds else {
                windowSum = 0; windowCount = 0; windowPeak = 0
                return
            }
            let rms = (windowSum / Double(windowCount)).squareRoot()
            let peakDB = decibels(fromAmplitude: windowPeak)
            let rmsDB = decibels(fromAmplitude: Float(rms))
            if peakDB > thresholds.peakDBFS, rmsDB > thresholds.shortTermRMSDBFS {
                result.foundAudibleWindow = true
            }
            windowSum = 0; windowCount = 0; windowPeak = 0
        }

        readLoop: while let buffer = session.output.copyNextSampleBuffer() {
            try autoreleasepool {
                defer { CMSampleBufferInvalidate(buffer) }
                try forEachChunk(of: buffer) { samples in
                    var sumOfSquares: Float = 0
                    vDSP_svesq(samples.baseAddress!, 1, &sumOfSquares, vDSP_Length(samples.count))
                    var chunkPeak: Float = 0
                    vDSP_maxmgv(samples.baseAddress!, 1, &chunkPeak, vDSP_Length(samples.count))

                    result.sumOfSquares += Double(sumOfSquares)
                    result.sampleCount += UInt64(samples.count)
                    result.peak = max(result.peak, chunkPeak)

                    guard thresholds != nil else { return }
                    // Window bookkeeping only matters in the early-exit mode.
                    // A chunk can span several windows, so this walks it.
                    var offset = 0
                    while offset < samples.count {
                        let take = min(windowValues - windowCount, samples.count - offset)
                        let slice = UnsafeBufferPointer(rebasing: samples[offset..<(offset + take)])
                        var sliceSum: Float = 0
                        vDSP_svesq(slice.baseAddress!, 1, &sliceSum, vDSP_Length(take))
                        var slicePeak: Float = 0
                        vDSP_maxmgv(slice.baseAddress!, 1, &slicePeak, vDSP_Length(take))
                        windowSum += Double(sliceSum)
                        windowPeak = max(windowPeak, slicePeak)
                        windowCount += take
                        offset += take
                        if windowCount >= windowValues { closeWindow() }
                    }
                }

                let frames = result.sampleCount / UInt64(max(1, session.channelCount))
                let unit = frames / UInt64(max(1, windowFrames))
                if unit != reportedUnit {
                    reportedUnit = unit
                    try progress.checkpoint(
                        LatheProgress(
                            fraction: min(1, Double(frames) / totalFrames),
                            stage: "analyse",
                            unitIndex: unit,
                            unitCount: UInt64((totalFrames / Double(windowFrames)).rounded())
                        )
                    )
                }
            }

            if result.foundAudibleWindow { break readLoop }
        }

        // The tail: a file shorter than one window, or a final partial window,
        // still has to be judged. Skipping it would make a 300 ms recording of
        // someone shouting read as silent.
        if !result.foundAudibleWindow { closeWindow() }

        if session.reader.status == .failed {
            throw LatheError.wrapping(
                session.reader.error ?? LatheError.underlying("AVAssetReader failed")
            )
        }
        return result
    }

    /// Hands each contiguous run of `Float` samples in a sample buffer to `body`.
    ///
    /// `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` is used rather
    /// than reaching into the block buffer directly because a decoder's output
    /// is not required to be one contiguous allocation, and code that assumes it
    /// is works until the day it meets a format where it is not.
    private static func forEachChunk(
        of buffer: CMSampleBuffer,
        _ body: (UnsafeBufferPointer<Float>) throws -> Void
    ) throws {
        var blockBuffer: CMBlockBuffer?
        var list = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            throw LatheError.encodingFailed(
                stage: "decode", code: status, reason: "could not read a decoded audio buffer"
            )
        }
        withExtendedLifetime(blockBuffer) {}

        for audioBuffer in UnsafeMutableAudioBufferListPointer(&list) {
            guard let data = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { continue }
            let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            try body(UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Float.self), count: count
            ))
        }
    }

    /// Amplitude (0...1) to dBFS, with a floor instead of `-inf`.
    static func decibels(fromAmplitude amplitude: Float) -> Float {
        guard amplitude > 0 else { return MeanVolume.digitalSilenceFloorDB }
        return 20 * log10(amplitude)
    }
}
