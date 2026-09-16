import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import LatheCore
import VideoToolbox

/// Re-encodes a video: codec, quality target, aspect-fit downscale, metadata
/// policy and audio disposition, in one pass, on the device, with no subprocess.
///
/// ```swift
/// let result = try await VideoTranscoder().transcode(
///     source: clip, to: smaller,
///     codec: .hevc, quality: .quality(0.55),
///     resize: .longestSide(1080), metadata: .stripLocation
/// )
/// print(result.usedHardwareAcceleration, result.outputByteCount)
/// ```
///
/// `AVAssetReader` decodes, `VideoToolbox` encodes, `AVAssetWriter` muxes. The
/// encoder is driven directly rather than through `AVAssetWriterInput`'s output
/// settings, and that is the load-bearing choice in this file: an
/// `AVVideoCompressionPropertiesKey` dictionary cannot set a constant quality on
/// every codec, cannot reach a property newer than the SDK's convenience keys,
/// and — the decisive one — gives no way to *read back* whether a hardware
/// encoder was actually used. Owning the `VTCompressionSession` makes all three
/// facts available, and ``VideoTranscodeResult`` reports them.
///
/// ## What it refuses to get wrong
///
/// **It never enlarges.** The target comes from ``ResizeTarget/resolve(from:)``,
/// which clamps to the source, so a `.longestSide(4000)` against a 720p clip is
/// a no-op rather than an upscale. The resolved size is then rounded *down* to
/// even dimensions, because 4:2:0 chroma has no way to represent an odd one; the
/// size actually encoded is reported as ``VideoTranscodeResult/pixelSize``.
///
/// **It never applies an `AVVideoComposition`.** Not for rotation, not for
/// resizing. See ``PixelScaler`` for what is used instead and what a composition
/// would have cost — the short version is that routing frames through a
/// compositor flattens Dolby Vision. Rotation is carried as the writer input's
/// `transform`, exactly as the source carried it, so a portrait video stays
/// portrait without a single pixel being moved.
///
/// **It never leaves a partial file.** Everything is written to a sibling
/// temporary file that is moved into place only after `finishWriting` reports
/// `.completed` and the file is non-empty. A cancellation, a codec failure or a
/// crash-free error therefore leaves `destination` exactly as it was — including
/// leaving a *previous* file intact.
///
/// **It never silently re-encodes the audio.** Where the destination container
/// accepts the source's audio as it stands, the encoded samples are copied
/// across untouched — no decode, no second generation of loss. See
/// ``AudioDisposition``.
///
/// ## Progress and cancellation
///
/// Progress is measured, not animated: the fraction is the current frame's
/// presentation time over the asset's duration, reported from the pump that
/// actually reads the frames. Cancellation is the ``ProgressHandle`` contract —
/// a sink returning `false`, an explicit ``ProgressHandle/cancel()``, or the
/// enclosing `Task` being cancelled — and is checked once per frame, so cancel
/// latency is one frame rather than one file. A cancelled transcode stops the
/// reader, cancels the writer, deletes the temporary file and throws
/// ``LatheError/cancelled(atUnit:)`` carrying the frame it stopped at.
///
/// Unlike ``ImageEncoder``, this does not run its body through ``LatheWork``.
/// `LatheWork` exists to keep a long *blocking* call off the cooperative pool;
/// nothing here blocks one, because `AVAssetWriterInput` calls back on its own
/// dispatch queues and the awaiting task is suspended the whole time. The other
/// half of `LatheWork`'s job — routing `Task` cancellation into the handle — is
/// done here directly with `withTaskCancellationHandler`.
///
/// ## HDR
///
/// Colour primaries, transfer function and matrix are carried from the source's
/// format description onto the encoder, so a wide-gamut or HLG source does not
/// come back tagged as Rec. 709. Dynamic HDR metadata is requested to be
/// preserved where the encoder offers that property. None of that makes this a
/// Dolby Vision-preserving transcode: a re-encode regenerates the bitstream, and
/// the per-frame RPU is not reconstructed. What is promised is narrower and
/// checkable — nothing in this path discards the colour information *before* the
/// encoder sees it.
public struct VideoTranscoder: Sendable {

    public init() {}

    // MARK: - Entry points

    /// Transcode one video.
    ///
    /// - Parameters:
    ///   - source: the video to read. A local file.
    ///   - destination: where to write. The extension picks the container —
    ///     `.mov`, `.mp4` or `.m4v`. Overwritten only on success.
    ///   - codec: the output codec. Creating the encoder *is* the capability
    ///     probe; an unavailable codec fails as
    ///     ``LatheError/encodeUnavailable(format:)`` before anything is written.
    ///   - quality: see ``QualityTarget``. ``QualityTarget/lossless`` is refused.
    ///   - resize: `nil` and ``ResizeTarget/none`` both mean "leave the pixel
    ///     dimensions alone".
    ///   - metadata: what to carry across. See ``VideoMetadata``.
    ///   - bFrames: see ``BFramePolicy``. The default allows them.
    ///   - passthroughAudio: copy the audio track through untouched where the
    ///     container accepts it, rather than re-encoding it.
    ///   - forcePreserve: keys restored after any strip.
    ///   - sink: receives progress; returning `false` from it cancels.
    ///
    /// - Throws: ``LatheError/encodeUnavailable(format:)``,
    ///   ``LatheError/invalidConfiguration(reason:)``,
    ///   ``LatheError/invalidInput(reason:)``,
    ///   ``LatheError/encodingFailed(stage:code:reason:)``, or
    ///   ``LatheError/cancelled(atUnit:)``.
    @discardableResult
    public func transcode(
        source: URL,
        to destination: URL,
        codec: VideoCodec = .hevc,
        quality: QualityTarget = .quality(0.65),
        resize: ResizeTarget? = nil,
        metadata: MetadataPolicy = .preserveAll,
        bFrames: BFramePolicy = .allow,
        passthroughAudio: Bool = true,
        forcePreserve: MetadataForcePreserve = .default,
        reporting sink: (any ProgressSink)? = nil
    ) async throws -> VideoTranscodeResult {
        let request = VideoTranscodeRequest(
            source: source,
            destination: destination,
            codec: codec,
            quality: quality,
            resize: resize ?? .none,
            metadata: metadata,
            forcePreserve: forcePreserve,
            bFrames: bFrames,
            passthroughAudio: passthroughAudio
        )
        return try await transcode(request, progress: ProgressHandle(sink: sink))
    }

    /// The same transcode against a request the caller already has, and a handle
    /// it already owns — so a batch can hold one handle across many files and
    /// stop all of them from one place.
    @discardableResult
    public func transcode(
        _ request: VideoTranscodeRequest,
        progress: ProgressHandle = .ignoring()
    ) async throws -> VideoTranscodeResult {
        try await withTaskCancellationHandler {
            do {
                return try await Self.perform(request, progress: progress)
            } catch {
                // One error vocabulary at the boundary. Two things arrive here
                // that are the same event wearing different clothes: a
                // `LatheError.cancelled` thrown by a progress checkpoint, and a
                // `CancellationError` from a pump whose task was cancelled from
                // outside. `wrapping` normalises both, and the frame index is
                // restored from the handle so the cancellation still says how far
                // it got — which is what a resumable batch needs.
                let normalised = LatheError.wrapping(error)
                if case .cancelled(nil) = normalised {
                    throw LatheError.cancelled(atUnit: progress.currentUnitIndex)
                }
                throw normalised
            }
        } onCancel: {
            progress.cancel()
        }
    }

    // MARK: - The transcode

    private static func perform(
        _ request: VideoTranscodeRequest,
        progress: ProgressHandle
    ) async throws -> VideoTranscodeResult {
        let started = Date()

        // MARK: Refuse before creating anything.
        try progress.checkpoint(LatheProgress(fraction: 0, stage: "probe"))
        // Configuration first, before the disk is touched at all: a request that
        // cannot be honoured should be refused identically whether or not the
        // source happens to exist.
        if case .lossless = request.quality {
            throw LatheError.invalidConfiguration(
                reason: "QualityTarget.lossless means \"re-encode nothing\", and VideoToolbox has no "
                    + "lossless H.264 or HEVC mode to reinterpret it as. Copying tracks through "
                    + "while rewriting the container's metadata is a different operation from "
                    + "transcoding; this one re-encodes by definition. Ask for a high "
                    + ".quality(_) if that is what was meant — note that quality 1.0 is still lossy."
            )
        }
        let fileType = try fileType(for: request.destination)
        try MediaProbe.requireReadableFile(at: request.source)
        guard request.source.standardizedFileURL != request.destination.standardizedFileURL else {
            throw LatheError.invalidConfiguration(
                reason: "the source and the destination are the same file; a transcode reads the "
                    + "whole source, so it cannot also be the thing being replaced"
            )
        }

        // MARK: Geometry.
        let asset = AVURLAsset(
            url: request.source,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let videoTrack = try await firstTrack(.video, of: asset, source: request.source)
        let audioTrack = try? await firstTrack(.audio, of: asset, source: request.source)

        let (naturalSize, transform) = try await videoTrack.load(.naturalSize, .preferredTransform)
        let (nominalFrameRate, videoRange) = try await videoTrack.load(.nominalFrameRate, .timeRange)
        let sourceFormat = (try? await videoTrack.load(.formatDescriptions))?.first
        let assetDuration = (try? await asset.load(.duration)) ?? videoRange.duration

        let coded = PixelSize(
            width: Int(naturalSize.width.rounded()),
            height: Int(naturalSize.height.rounded())
        )
        guard !coded.isEmpty else {
            throw LatheError.invalidInput(
                reason: "\(request.source.lastPathComponent)'s video track reports a zero size"
            )
        }

        // The resize arithmetic runs against the size a *viewer* sees, exactly as
        // it does for stills: a portrait phone video is stored landscape with a
        // quarter turn in the track matrix, and fitting a box against the stored
        // axes gives a differently *shaped* result from the one the caller drew
        // on screen. The encoder then needs the answer back on the stored axes,
        // because that is what the decoder hands it.
        let display = MediaProbe.applying(transform, to: coded)
        let targetDisplay = request.resize.resolve(from: display)
        let targetStored = MediaProbe.applying(transform, to: targetDisplay)
        let encodeSize = evenDimensions(targetStored)
        let needsScaling = encodeSize != coded

        // MARK: The encoder. Creating it is the capability probe.
        let compressor = try VideoCompressor(
            codec: request.codec,
            size: encodeSize,
            quality: request.quality,
            bFrames: request.bFrames,
            sourceFormat: sourceFormat,
            expectedFrameRate: Double(nominalFrameRate)
        )
        defer { compressor.invalidate() }
        let scaler = needsScaling ? try PixelScaler(target: encodeSize) : nil

        // MARK: The reader.
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw LatheError.invalidInput(
                reason: "\(request.source.lastPathComponent) could not be opened for reading: "
                    + (error as NSError).localizedDescription
            )
        }
        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    decodePixelFormat(for: sourceFormat, codec: request.codec),
                // IOSurface-backed so the hardware encoder can take the buffer
                // without a trip through main memory.
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ]
        )
        // Safe because every buffer is consumed — encoded or appended — before
        // the next one is asked for.
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw LatheError.invalidInput(
                reason: "\(request.source.lastPathComponent)'s video track cannot be decoded here"
            )
        }
        reader.add(videoOutput)

        // MARK: The writer.
        let scratch = scratchURL(beside: request.destination)
        try? FileManager.default.createDirectory(
            at: request.destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: scratch, fileType: fileType)
        } catch {
            throw LatheError.writeFailed(
                path: request.destination.lastPathComponent,
                reason: (error as NSError).localizedDescription
            )
        }
        writer.metadata = await VideoMetadata.items(
            for: request.metadata, from: asset, forcePreserve: request.forcePreserve
        )

        // `outputSettings: nil` is the passthrough input: this writer input is
        // handed sample buffers that VideoToolbox has *already* encoded, and the
        // output format description travels on the first of them. Giving it
        // settings instead would make AVFoundation create a second encoder and
        // re-encode what was just encoded.
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        videoInput.expectsMediaDataInRealTime = false
        // The rotation, carried rather than applied. See the note on
        // `AVVideoComposition` in this type's documentation.
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else {
            throw LatheError.encodeUnavailable(
                format: "\(request.codec.rawValue) in \(request.destination.pathExtension)"
            )
        }
        writer.add(videoInput)

        let audio = try await audioPlan(
            for: audioTrack, request: request, reader: reader, writer: writer
        )

        // MARK: Chapters.
        //
        // Attached after the video input, because the association is made
        // between two inputs and the writer only accepts it while it is still
        // being configured. Associated with the VIDEO track: a player looks for
        // the chapter list on the track it is showing.
        let sourceChapters = await ChapterTrack.read(from: asset)
            .normalizedChapters(totalDuration: assetDuration.seconds)
        let chapterAttachment = ChapterTrack.makeInput(
            for: sourceChapters, writer: writer, associatedWith: videoInput
        )

        // MARK: Run.
        var sessionStart = videoRange.start
        if let audioStart = audio?.trackStart, audioStart < sessionStart { sessionStart = audioStart }
        if !sessionStart.isValid || sessionStart < .zero { sessionStart = .zero }

        guard reader.startReading() else {
            throw LatheError.wrapping(
                reader.error ?? LatheError.encodingFailed(
                    stage: "read", code: nil, reason: "the reader refused to start"
                )
            )
        }
        guard writer.startWriting() else {
            throw LatheError.wrapping(
                writer.error ?? LatheError.writeFailed(
                    path: request.destination.lastPathComponent, reason: "the writer refused to start"
                )
            )
        }
        writer.startSession(atSourceTime: sessionStart)

        // Started, not awaited — a writer drives its inputs together, so waiting
        // for the text samples before feeding the video waits forever. See
        // ``ChapterTrack``.
        let chapterWrite = chapterAttachment.input.map {
            ChapterTrack.beginWriting(sourceChapters, to: $0)
        }

        var finished = false
        defer {
            if !finished { writer.cancelWriting() }
            reader.cancelReading()
            try? FileManager.default.removeItem(at: scratch)
        }

        let state = TranscodeState()
        let estimatedFrames = UInt64(
            max(0, (assetDuration.seconds * Double(nominalFrameRate)).rounded())
        )
        let fallbackFrameDuration = nominalFrameRate > 0
            ? CMTime(seconds: 1 / Double(nominalFrameRate), preferredTimescale: 600)
            : CMTime(value: 1, timescale: 30)

        let videoPump = WriterInputPump(input: videoInput, label: "video") {
            // One step: drain what the encoder has produced, else feed it more,
            // else flush it, else finish. Only ever called on this pump's queue.
            if let encoded = compressor.queue.pop() {
                guard videoInput.append(encoded) else {
                    throw Self.failure(of: writer, stage: "mux", what: "an encoded video frame")
                }
                state.observe(end: CMSampleBufferGetOutputPresentationTimeStamp(encoded)
                    + CMSampleBufferGetDuration(encoded))
                return true
            }
            if let recorded = compressor.queue.recordedFailure { throw recorded }
            if state.flushed { return false }

            guard let sample = videoOutput.copyNextSampleBuffer() else {
                // The reader is done. Flush the frames the encoder is still
                // holding back for reordering, then keep draining.
                try compressor.finish()
                state.flushed = true
                return true
            }
            guard let image = CMSampleBufferGetImageBuffer(sample) else { return true }

            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetDuration(sample)
            let elapsed = (presentation - sessionStart).seconds
            let total = assetDuration.seconds
            try progress.checkpoint(LatheProgress(
                fraction: total > 0 ? elapsed / total : nil,
                stage: "encode",
                unitIndex: state.frameCount,
                unitCount: estimatedFrames
            ))

            try compressor.encode(
                try scaler?.scaled(image) ?? image,
                at: presentation,
                duration: duration.isValid && duration.value > 0 ? duration : fallbackFrameDuration
            )
            state.frameCount += 1
            return true
        }

        var audioPump: WriterInputPump?
        if let audio {
            audioPump = WriterInputPump(input: audio.input, label: "audio") {
                guard let sample = audio.output.copyNextSampleBuffer() else { return false }
                guard audio.input.append(sample) else {
                    throw Self.failure(of: writer, stage: "mux", what: "an audio sample")
                }
                state.observe(end: CMSampleBufferGetOutputPresentationTimeStamp(sample)
                    + CMSampleBufferGetDuration(sample))
                // Audio reports no progress — the video pump owns the fraction —
                // but it must still stop when the job is cancelled.
                try progress.checkCancellation()
                return true
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await videoPump.run() }
            if let audioPump { group.addTask { try await audioPump.run() } }
            try await group.waitForAll()
        }

        if reader.status == .failed {
            throw LatheError.wrapping(reader.error ?? LatheError.encodingFailed(
                stage: "read", code: nil, reason: "the reader failed without an error"
            ))
        }

        if let end = state.endTime, end > sessionStart {
            writer.endSession(atSourceTime: end)
        }
        let chapterOutcome = await chapterWrite?.value
        let preservedChapters = chapterOutcome?.written ?? 0
        await writer.finishWriting()
        finished = true

        guard writer.status == .completed else {
            throw Self.failure(of: writer, stage: "finish", what: "the file")
        }

        let outputByteCount = MediaProbe.byteCount(of: scratch) ?? 0
        guard outputByteCount > 0 else {
            throw LatheError.encodingFailed(
                stage: "finish", code: nil,
                reason: "the writer completed but produced no bytes"
            )
        }

        // The move is the point: `destination` holds either the previous file or
        // a complete new one, and never a truncated one. A sibling rather than
        // the system temporary directory, because a move across volumes is a
        // copy, and the destination is where the caller already decided there is
        // room.
        do {
            _ = try FileManager.default.replaceItemAt(request.destination, withItemAt: scratch)
        } catch {
            throw LatheError.writeFailed(
                path: request.destination.lastPathComponent,
                reason: (error as NSError).localizedDescription
            )
        }

        let writtenDuration = (state.endTime.map { ($0 - sessionStart).seconds })
            ?? assetDuration.seconds
        let inputByteCount = MediaProbe.byteCount(of: request.source) ?? 0
        if outputByteCount > inputByteCount, inputByteCount > 0 {
            // Not an error — the caller may have asked for exactly this by
            // requesting a higher quality than the source was encoded at — but a
            // recompression batch that grows the library is worth noticing on
            // the first file rather than on the last.
            LatheLog.video.info(
                """
                \(LatheLog.publicPath(request.destination), privacy: .public) grew: \
                \(inputByteCount, privacy: .public) → \(outputByteCount, privacy: .public) bytes
                """
            )
        }

        // The terminal tick. A UI that never sees unitIndex == unitCount looks
        // stuck at 97% forever; `ProgressHandle` never throttles this one away.
        progress.report(LatheProgress(
            fraction: 1, stage: "encode",
            unitIndex: max(state.frameCount, estimatedFrames),
            unitCount: max(state.frameCount, estimatedFrames)
        ))

        return VideoTranscodeResult(
            output: request.destination,
            codec: request.codec,
            pixelSize: encodeSize,
            duration: writtenDuration,
            frameCount: state.frameCount,
            inputByteCount: inputByteCount,
            outputByteCount: outputByteCount,
            wallTime: Date().timeIntervalSince(started),
            usedHardwareAcceleration: compressor.usedHardwareAcceleration,
            frameReordering: compressor.frameReordering,
            rateControl: compressor.rateControl,
            audio: audio?.disposition ?? .none,
            preservedChapterCount: preservedChapters,
            droppedChapterCount: max(0, sourceChapters.count - preservedChapters),
            chapterLossReason: sourceChapters.count > preservedChapters
                ? (chapterAttachment.reason ?? chapterOutcome?.failure)
                : nil
        )
    }

    // MARK: - Audio

    /// What the audio track is doing: its reader output, its writer input, and
    /// which of the two answers that is.
    private struct AudioPlan {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        let disposition: AudioDisposition
        let trackStart: CMTime
    }

    /// Prefers passthrough, falls back to AAC, and **asks the writer** which one
    /// is possible rather than consulting a table of container/codec pairs.
    ///
    /// Passthrough is the default because re-encoding AAC to AAC is a second
    /// generation of loss bought for nothing: the caller asked for a smaller
    /// *video* track. It is not always available — a PCM track in a `.mov`
    /// being rewrapped as `.mp4`, for instance — and where the writer will not
    /// take the source format, the audio is decoded and re-encoded to AAC rather
    /// than dropped.
    private static func audioPlan(
        for track: AVAssetTrack?,
        request: VideoTranscodeRequest,
        reader: AVAssetReader,
        writer: AVAssetWriter
    ) async throws -> AudioPlan? {
        guard let track else { return nil }
        let format = (try? await track.load(.formatDescriptions))?.first
        let trackStart = (try? await track.load(.timeRange))?.start ?? .zero

        if request.passthroughAudio, let format {
            let input = AVAssetWriterInput(
                mediaType: .audio, outputSettings: nil, sourceFormatHint: format
            )
            input.expectsMediaDataInRealTime = false
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            if writer.canAdd(input), reader.canAdd(output) {
                writer.add(input)
                reader.add(output)
                return AudioPlan(
                    output: output, input: input, disposition: .passedThrough, trackStart: trackStart
                )
            }
            LatheLog.video.info(
                """
                this container will not take the source's audio as it stands; re-encoding to AAC \
                rather than dropping the track
                """
            )
        }

        // Decode to packed 32-bit float PCM and let AVFoundation encode AAC.
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw LatheError.invalidInput(reason: "the audio track cannot be decoded here")
        }

        let basic = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let channels = max(1, Int(basic?.mChannelsPerFrame ?? 2))
        let sampleRate = basic.map(\.mSampleRate).flatMap { $0 > 0 ? $0 : nil } ?? 44_100

        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                // 64 kbit/s per channel: transparent enough for speech and
                // ordinary capture, and a figure a caller can predict.
                AVEncoderBitRateKey: 64_000 * channels,
            ]
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw LatheError.encodeUnavailable(format: "AAC in \(writer.outputFileType.rawValue)")
        }
        reader.add(output)
        writer.add(input)
        return AudioPlan(output: output, input: input, disposition: .reencodedAAC, trackStart: trackStart)
    }

    // MARK: - Geometry and formats

    /// Rounds *down* to even dimensions.
    ///
    /// 4:2:0 chroma is subsampled by two in each direction, so an odd width or
    /// height has no representation; encoders either refuse it or silently pad,
    /// and a padded frame is a frame with a green edge. Down rather than up
    /// because the whole resize path is a downscale and rounding up could exceed
    /// a cap the caller set for a reason.
    static func evenDimensions(_ size: PixelSize) -> PixelSize {
        PixelSize(
            width: max(2, size.width - size.width % 2),
            height: max(2, size.height - size.height % 2)
        )
    }

    /// The pixel format to decode into.
    ///
    /// Three cases, and the middle one is the one that matters: decoding an HDR
    /// source into an 8-bit buffer destroys it *before* the encoder is reached,
    /// and no encoder setting can get it back. A PQ or HLG transfer function is
    /// the signal that the source is at least 10-bit.
    static func decodePixelFormat(for format: CMFormatDescription?, codec: VideoCodec) -> OSType {
        if codec.needsAlpha { return kCVPixelFormatType_32BGRA }

        let transfer = format.flatMap {
            CMFormatDescriptionGetExtension(
                $0, extensionKey: kCMFormatDescriptionExtension_TransferFunction
            )
        } as? String
        let isHighDynamicRange = transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            || transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        if isHighDynamicRange { return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange }

        let isFullRange = (format.flatMap {
            CMFormatDescriptionGetExtension(
                $0, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo
            )
        } as? NSNumber)?.boolValue ?? false
        return isFullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    /// The container named by the destination's extension.
    ///
    /// Named rather than sniffed, and refused rather than guessed: writing an
    /// HEVC track into a container that cannot index it produces a file that
    /// plays nowhere, and finding that out at `finishWriting` is far too late.
    static func fileType(for destination: URL) throws -> AVFileType {
        switch destination.pathExtension.lowercased() {
        case "mov", "qt": .mov
        case "mp4": .mp4
        case "m4v": .m4v
        default:
            throw LatheError.invalidConfiguration(
                reason: "no video container is named by the extension "
                    + "\"\(destination.pathExtension)\"; use mov, mp4 or m4v"
            )
        }
    }

    private static func firstTrack(
        _ mediaType: AVMediaType,
        of asset: AVURLAsset,
        source: URL
    ) async throws -> AVAssetTrack {
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: mediaType)
        } catch {
            throw LatheError.invalidInput(
                reason: "\(source.lastPathComponent) is not a media file AVFoundation can open"
            )
        }
        guard let track = tracks.first else {
            throw LatheError.invalidInput(
                reason: "\(source.lastPathComponent) has no \(mediaType.rawValue) track"
            )
        }
        return track
    }

    private static func scratchURL(beside destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".lathe-\(UUID().uuidString).\(destination.pathExtension)"
        )
    }

    /// The writer's own error where it has one, so a mux failure names its cause
    /// rather than the symptom.
    private static func failure(
        of writer: AVAssetWriter,
        stage: String,
        what: String
    ) -> LatheError {
        if let error = writer.error { return LatheError.wrapping(error) }
        return LatheError.encodingFailed(
            stage: stage, code: nil, reason: "the writer refused \(what) without reporting an error"
        )
    }
}

// MARK: - Shared state

/// The little that both pumps touch.
///
/// `frameCount` and `flushed` belong to the video pump's serial queue and are
/// unsynchronised on purpose; `endTime` is written by both pumps and is locked.
private final class TranscodeState: @unchecked Sendable {
    var frameCount: UInt64 = 0
    var flushed = false

    private let lock = NSLock()
    private var latest: CMTime = .invalid

    /// The end of the last sample appended to either input, which is where the
    /// session is ended — so the output's duration is what was actually written
    /// rather than what the source claimed.
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
/// **Why this is not a `while !input.isReadyForMoreMediaData { sleep }` loop.**
/// That shape appears to work with a single input and deadlocks with two: the
/// video input goes not-ready part way through and never comes back, while the
/// writer's status stays `.writing` and reports no error at all. Polling is not
/// how the writer expects to be driven — `requestMediaDataWhenReady(on:using:)`
/// is, and with one pump per input the writer schedules both and does its own
/// interleaving. The failure it replaces is worth naming because it is
/// completely silent: nothing fails, the job simply stops.
///
/// (The test-support fixture writer carries the same machinery for the same
/// reason. It is duplicated rather than shared because nothing outside this
/// package may import the fixtures, and a hazard this quiet is worth stating
/// twice.)
private final class WriterInputPump: @unchecked Sendable {

    private let input: AVAssetWriterInput
    private let label: String
    /// Performs one step. Returns `false` when there is nothing left to do.
    /// Called only on this pump's serial queue.
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

    /// Runs until the source is exhausted, a step throws, or the enclosing task
    /// is cancelled.
    ///
    /// The cancellation handler is not decoration. When one pump fails, the task
    /// group cancels the other and then *waits* for it — and a pump waiting on a
    /// writer that is no longer scheduling anything would wait forever, turning
    /// a clean failure into a hang. Stopping on cancellation is what keeps the
    /// two-input case terminating.
    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()

                let queue = DispatchQueue(label: "dev.lathe.video.\(label)")
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

    /// Resumes the continuation exactly once. The callback can fire again after
    /// `markAsFinished()`, and resuming twice traps.
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
