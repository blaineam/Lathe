import AVFoundation
import CoreMedia
import Foundation
import LatheCore

/// Re-encodes an audio file: codec, bitrate, sample rate, channel policy and
/// metadata, in one pass, on the device, with no subprocess.
///
/// ```swift
/// let result = try await AudioTranscoder().transcode(
///     source: flac, to: m4a, codec: .aac, quality: .quality(0.5)
/// )
/// switch result.outcome {
/// case .transcoded:      print(result.source.codecName, "→", result.destination!.codecName)
/// case let .skipped(why): print("left alone:", why)
/// }
/// ```
///
/// `AVAssetReader` decodes, `AVAssetWriter` encodes and muxes. Unlike the video
/// path there is no reason to drive the codec directly: an audio encoder has no
/// hardware/software question worth reading back and no property newer than the
/// convenience keys, so `AVAssetWriterInput`'s output settings *are* the
/// interface.
///
/// ## What it refuses to get wrong
///
/// **It will not re-encode already-lossy audio for nothing.** This is the
/// headline, and the default. Transcoding a 128 kbps MP3 to 128 kbps AAC stacks
/// a second psychoacoustic model on the first one's artefacts and routinely
/// produces a *larger* file that sounds worse; a library optimiser that does
/// that has made every file worse and is not reversible. So a lossy source is
/// re-encoded only when the target bitrate is at most three-quarters of the
/// source's, and otherwise **nothing is written at all** — the destination is
/// untouched and ``AudioTranscodeResult/outcome`` explains itself. See
/// ``LossySourceRule``, and ``plan(for:)`` for asking before doing.
///
/// **It never upsamples.** The output sample rate is `min(requested, source)`
/// and the output channel count is `min(requested, source)`. A 22 kHz mono voice
/// memo cannot come back as 48 kHz stereo — that is twice the bytes for exactly
/// the same information, and it is what a fixed "encode everything at 48/stereo"
/// preset does to a library of voice memos.
///
/// **It never silently discards channels.** ``ChannelPolicy/preserve`` is the
/// default, a multi-channel source keeps its channel layout, and whatever
/// happened is reported as ``AudioTranscodeResult/channels`` — including the one
/// case where preservation is impossible, which is named rather than folded in
/// with the downmixes the caller asked for.
///
/// **It never leaves a partial file.** Everything is written to a sibling
/// temporary file that is moved into place only after `finishWriting` reports
/// `.completed` and the file is non-empty. A cancellation, an encoder failure or
/// a refusal therefore leaves the destination exactly as it was, including
/// leaving a *previous* file intact.
///
/// **It never reports what it did not check.** Source and destination facts in
/// ``AudioTranscodeResult`` are read back from the files with
/// ``AudioInspector``, not copied from the settings dictionary handed to the
/// encoder.
///
/// ## Chapters are preserved
///
/// An audiobook's chapters are not metadata items. They are a separate text
/// track plus a track association, which is why a transcode that copies every
/// metadata item across can still produce one long unmarked block — the
/// chapters were never in the metadata to copy. Carrying them means muxing a
/// second input, encoding each title as a text sample, and rebuilding the
/// association; see ``ChapterTrack``.
///
/// Where the destination container cannot hold a chapter track — a WAV has
/// nowhere to put one — the chapters are lost and counted in
/// ``AudioTranscodeResult/droppedChapterCount`` rather than silently absent.
/// ``AudioTranscodeResult/preservedChapterCount`` reports the ones that made
/// it, so a caller never has to infer which happened.
///
/// ## Opus
///
/// Not offered, and not substituted. AVFoundation decodes Opus and has no
/// encoder for it on any Apple platform, so naming an `.opus` destination is
/// refused by name — see ``AudioCodec``. Quietly writing AAC into a file the
/// caller asked to be Opus would be worse than refusing: it would be a silent
/// answer to a question that was asked for a reason.
///
/// ## Progress and cancellation
///
/// Progress is measured, not animated: the fraction is the current buffer's
/// presentation time over the track's duration. Cancellation is the
/// ``ProgressHandle`` contract — a sink returning `false`, an explicit
/// ``ProgressHandle/cancel()``, or the enclosing `Task` being cancelled — and is
/// checked once per decoded buffer. A cancelled transcode stops the reader,
/// cancels the writer, deletes the temporary file and throws
/// ``LatheError/cancelled(atUnit:)``.
public struct AudioTranscoder: Sendable {

    public init() {}

    // MARK: - Entry points

    /// Transcode one audio file.
    ///
    /// - Parameters:
    ///   - source: the file to read. A local file.
    ///   - destination: where to write. The extension picks the container; see
    ///     ``AudioContainer``. Overwritten only on success, and not written at
    ///     all when the transcode is skipped.
    ///   - codec: ``AudioCodec/aac`` or ``AudioCodec/appleLossless``.
    ///   - quality: see ``AudioTranscodeRequest/quality``.
    ///   - sampleRate: hertz, clamped to the source's. `nil` keeps the source's.
    ///   - channels: see ``ChannelPolicy``.
    ///   - metadata: what to carry across, artwork included. See
    ///     ``AudioMetadata``.
    ///   - lossySources: when an already-lossy source may be re-encoded. See
    ///     ``LossySourceRule``.
    ///   - keepLargerOutput: keep a result that came out bigger than the source.
    ///   - forcePreserve: keys restored after any strip.
    ///   - sink: receives progress; returning `false` from it cancels.
    ///
    /// - Returns: a result whose ``AudioTranscodeResult/outcome`` is either
    ///   ``AudioTranscodeOutcome/transcoded`` or
    ///   ``AudioTranscodeOutcome/skipped(_:)``. **A skip is a successful return,
    ///   not an error** — it is the expected outcome for a library pass over
    ///   material that is already efficiently compressed, and making it a thrown
    ///   error would mean every caller catching the normal case.
    ///
    /// - Throws: ``LatheError/unsupportedOnThisPlatform(feature:)`` for a codec
    ///   or container nothing here can write;
    ///   ``LatheError/invalidConfiguration(reason:)`` for a contradictory
    ///   request; ``LatheError/invalidInput(reason:)`` for a file with no audio;
    ///   ``LatheError/encodingFailed(stage:code:reason:)``; or
    ///   ``LatheError/cancelled(atUnit:)``.
    @discardableResult
    public func transcode(
        source: URL,
        to destination: URL,
        codec: AudioCodec = .aac,
        quality: QualityTarget = .quality(0.5),
        sampleRate: Int? = nil,
        channels: ChannelPolicy = .preserve,
        metadata: MetadataPolicy = .preserveAll,
        lossySources: LossySourceRule = .default,
        keepLargerOutput: Bool = false,
        forcePreserve: MetadataForcePreserve = .default,
        reporting sink: (any ProgressSink)? = nil
    ) async throws -> AudioTranscodeResult {
        let request = AudioTranscodeRequest(
            source: source,
            destination: destination,
            codec: codec,
            quality: quality,
            sampleRate: sampleRate,
            channels: channels,
            metadata: metadata,
            forcePreserve: forcePreserve,
            lossySources: lossySources,
            keepLargerOutput: keepLargerOutput
        )
        return try await transcode(request, progress: ProgressHandle(sink: sink))
    }

    /// The same transcode against a request the caller already has, and a handle
    /// it already owns — so a batch can hold one handle across many files and
    /// stop all of them from one place.
    @discardableResult
    public func transcode(
        _ request: AudioTranscodeRequest,
        progress: ProgressHandle = .ignoring()
    ) async throws -> AudioTranscodeResult {
        try await withTaskCancellationHandler {
            do {
                return try await Self.perform(request, progress: progress)
            } catch {
                // One error vocabulary at the boundary: a `LatheError.cancelled`
                // from a checkpoint and a `CancellationError` from a pump whose
                // task was cancelled from outside are the same event in
                // different clothes.
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

    // MARK: - Planning

    /// What ``transcode(_:progress:)`` would do with this request, without
    /// touching the destination.
    ///
    /// The "inspect and decide" seam. Everything expensive about a transcode is
    /// the encode, and every decision this type makes is taken from the
    /// container headers before a single sample is decoded — so a caller can
    /// have the decision for free, show it to a user, sort a queue by predicted
    /// saving, or override the rule with ``LossySourceRule/allow`` on the files
    /// where it disagrees.
    public func plan(for request: AudioTranscodeRequest) async throws -> AudioTranscodePlan {
        let container = try Self.container(for: request.destination)
        try Self.validate(request, container: container)
        let info = try await AudioInspector().inspect(request.source)
        guard let stream = info.stream else {
            throw LatheError.invalidInput(
                reason: "\(info.fileName) has no audio track to transcode"
            )
        }
        guard let target = Self.resolveTarget(request, source: stream) else {
            throw Self.unencodableRate(stream, codec: request.codec)
        }
        return AudioTranscodePlan(
            source: stream,
            skipReason: Self.skipReason(request, source: stream, target: target),
            targetCodec: request.codec,
            targetBitsPerSecond: target.bitsPerSecond,
            targetSampleRate: target.sampleRate,
            targetChannelCount: target.channels.outputChannelCount,
            isSecondGenerationLossy: stream.isLossy && !request.codec.isLossless
        )
    }

    // MARK: - The transcode

    private static func perform(
        _ request: AudioTranscodeRequest,
        progress: ProgressHandle
    ) async throws -> AudioTranscodeResult {
        let started = Date()

        // MARK: Refuse before creating anything.
        try progress.checkpoint(LatheProgress(fraction: 0, stage: "probe"))
        // Configuration first, before the disk is touched: a request that cannot
        // be honoured is refused identically whether or not the source exists.
        let container = try container(for: request.destination)
        try validate(request, container: container)
        try AudioFiles.requireReadableFile(at: request.source)
        guard request.source.standardizedFileURL != request.destination.standardizedFileURL else {
            throw LatheError.invalidConfiguration(
                reason: "the source and the destination are the same file; a transcode reads the "
                    + "whole source, so it cannot also be the thing being replaced"
            )
        }

        let info = try await AudioInspector().inspect(request.source)
        guard let sourceStream = info.stream else {
            throw LatheError.invalidInput(
                reason: "\(info.fileName) has no audio track to transcode"
            )
        }
        let inputByteCount = info.byteCount ?? 0
        guard let target = resolveTarget(request, source: sourceStream) else {
            throw unencodableRate(sourceStream, codec: request.codec)
        }

        // MARK: The rule. Refusing is a *result*, not an error.
        if let reason = skipReason(request, source: sourceStream, target: target) {
            LatheLog.audio.info(
                """
                \(LatheLog.publicPath(request.source), privacy: .public) left alone: \
                \(String(describing: reason), privacy: .public)
                """
            )
            return AudioTranscodeResult(
                output: nil,
                outcome: .skipped(reason),
                source: sourceStream,
                destination: nil,
                inputByteCount: inputByteCount,
                outputByteCount: 0,
                wallTime: Date().timeIntervalSince(started),
                channels: target.channels,
                metadataItemsWritten: 0,
                carriedArtwork: false,
                droppedChapterCount: info.chapterCount
            )
        }

        // MARK: Reader.
        let asset = try await AudioFiles.asset(at: request.source)
        let sourceChapters = await ChapterTrack.read(from: asset)
            .normalizedChapters(totalDuration: info.duration)
        guard let track = try await AudioFiles.firstAudioTrack(of: asset) else {
            throw LatheError.invalidInput(reason: "\(info.fileName) has no audio track to transcode")
        }
        let formatDescription = (try? await track.load(.formatDescriptions))?.first
        let trackRange = (try? await track.load(.timeRange)) ?? CMTimeRange(
            start: .zero, duration: CMTime(seconds: info.duration, preferredTimescale: 600)
        )

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw LatheError.invalidInput(
                reason: "\(info.fileName) could not be opened for reading: "
                    + (error as NSError).localizedDescription
            )
        }
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: decodeSettings(for: request.codec, source: sourceStream)
        )
        // Safe: every buffer is appended before the next one is asked for.
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw LatheError.invalidInput(
                reason: "\(info.fileName)'s audio track cannot be decoded to PCM here"
            )
        }
        reader.add(output)

        // MARK: Writer.
        let scratch = scratchURL(beside: request.destination)
        try? FileManager.default.createDirectory(
            at: request.destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: scratch, fileType: container.fileType)
        } catch {
            throw LatheError.writeFailed(
                path: request.destination.lastPathComponent,
                reason: (error as NSError).localizedDescription
            )
        }

        let metadata = await AudioMetadata.plan(
            for: request.metadata, from: asset, container: container,
            forcePreserve: request.forcePreserve
        )
        writer.metadata = metadata.items

        let settings = encodeSettings(
            request, target: target, sourceFormat: formatDescription, source: sourceStream
        )
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            // The capability answer, asked of the object that would have to
            // honour it rather than looked up in a table of codec/container
            // pairs.
            throw LatheError.encodeUnavailable(
                format: "\(request.codec.codecName) in \(container.rawValue)"
            )
        }
        writer.add(input)

        // MARK: Chapters.
        //
        // After the audio input is attached, because the association is made
        // between two inputs and the writer will only accept it while it is
        // still being configured. A container that cannot hold a chapter track
        // returns nil rather than failing the transcode: a WAV has nowhere to
        // put one, and refusing the whole job over it would be worse than
        // producing the file that was asked for and reporting the loss.
        let chapterAttachment = ChapterTrack.makeInput(
            for: sourceChapters, writer: writer, associatedWith: input
        )

        // MARK: Run.
        guard reader.startReading() else {
            throw LatheError.wrapping(reader.error ?? LatheError.encodingFailed(
                stage: "read", code: nil, reason: "the reader refused to start"
            ))
        }
        guard writer.startWriting() else {
            throw LatheError.wrapping(writer.error ?? LatheError.writeFailed(
                path: request.destination.lastPathComponent,
                reason: "the writer refused to start"
            ))
        }
        let sessionStart = trackRange.start.isValid && trackRange.start >= .zero
            ? trackRange.start : .zero
        writer.startSession(atSourceTime: sessionStart)

        // Started here and awaited after the audio pump, not before it: the
        // writer drives its inputs together, so waiting for the text samples to
        // land before feeding the audio waits forever. See ``ChapterTrack``.
        let chapterWrite = chapterAttachment.input.map {
            ChapterTrack.beginWriting(sourceChapters, to: $0)
        }

        var finished = false
        defer {
            if !finished { writer.cancelWriting() }
            reader.cancelReading()
            try? FileManager.default.removeItem(at: scratch)
        }

        let totalSeconds = max(info.duration, sourceStream.duration)
        let estimatedFrames = UInt64(max(0, (totalSeconds * max(1, target.sampleRate)).rounded()))
        let state = TranscodeState()

        let pump = WriterInputPump(input: input, label: "audio") {
            guard let sample = output.copyNextSampleBuffer() else { return false }

            // Read everything wanted from the buffer *before* appending it, and
            // never invalidate it afterwards. `AVAssetWriterInput.append` takes
            // a reference rather than a copy, and calling
            // `CMSampleBufferInvalidate` on a buffer the writer is still
            // holding does not fail — the encoder simply stops producing, the
            // writer's status stays `.writing`, and the job hangs with no error
            // anywhere. (Measured. It is the same class of silent stall as the
            // polling loop the pump exists to avoid.)
            let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetDuration(sample)
            let frames = UInt64(max(0, CMSampleBufferGetNumSamples(sample)))

            let elapsed = (presentation - sessionStart).seconds
            try progress.checkpoint(LatheProgress(
                fraction: totalSeconds > 0 ? min(1, max(0, elapsed / totalSeconds)) : nil,
                stage: "encode",
                unitIndex: state.frameCount,
                unitCount: estimatedFrames
            ))

            guard input.append(sample) else {
                throw failure(of: writer, stage: "mux", what: "a decoded audio buffer")
            }
            state.frameCount += frames
            state.observe(end: presentation + duration)
            return true
        }
        try await pump.run()

        if reader.status == .failed {
            throw LatheError.wrapping(reader.error ?? LatheError.encodingFailed(
                stage: "read", code: nil, reason: "the reader failed without an error"
            ))
        }

        if let end = state.endTime, end > sessionStart {
            writer.endSession(atSourceTime: end)
        }
        // The chapter pump runs alongside the audio one; its samples have to be
        // in before the file is closed.
        let chapterOutcome = await chapterWrite?.value
        let preservedChapters = chapterOutcome?.written ?? 0
        let chapterLossReason = chapterAttachment.reason ?? chapterOutcome?.failure
        await writer.finishWriting()
        finished = true

        guard writer.status == .completed else {
            throw failure(of: writer, stage: "finish", what: "the file")
        }

        let outputByteCount = AudioFiles.byteCount(of: scratch) ?? 0
        guard outputByteCount > 0 else {
            throw LatheError.encodingFailed(
                stage: "finish", code: nil, reason: "the writer completed but produced no bytes"
            )
        }

        // MARK: The last guard.
        //
        // The bitrate arithmetic above is a prediction; this is the measurement.
        // An encoder is entitled to disagree, and replacing a good file with a
        // bigger one is the failure this whole module exists to prevent — so by
        // default the result is thrown away and the destination left alone.
        if outputByteCount > inputByteCount, inputByteCount > 0, !request.keepLargerOutput {
            LatheLog.audio.info(
                """
                \(LatheLog.publicPath(request.source), privacy: .public) discarded: the re-encode \
                grew from \(inputByteCount, privacy: .public) to \
                \(outputByteCount, privacy: .public) bytes
                """
            )
            return AudioTranscodeResult(
                output: nil,
                outcome: .skipped(.outputWouldBeLarger(
                    inputByteCount: inputByteCount, outputByteCount: outputByteCount
                )),
                source: sourceStream,
                destination: nil,
                inputByteCount: inputByteCount,
                outputByteCount: 0,
                wallTime: Date().timeIntervalSince(started),
                channels: target.channels,
                metadataItemsWritten: 0,
                carriedArtwork: false,
                droppedChapterCount: info.chapterCount
            )
        }

        // The move is the point: the destination holds either the previous file
        // or a complete new one, and never a truncated one. A sibling rather
        // than the system temporary directory, because a move across volumes is
        // a copy, and the destination is where the caller already decided there
        // is room.
        do {
            _ = try FileManager.default.replaceItemAt(request.destination, withItemAt: scratch)
        } catch {
            throw LatheError.writeFailed(
                path: request.destination.lastPathComponent,
                reason: (error as NSError).localizedDescription
            )
        }

        // Read back, rather than repeat the settings dictionary as if it were an
        // outcome.
        let written = try? await AudioInspector().inspect(request.destination)

        // The terminal tick. A UI that never sees unitIndex == unitCount looks
        // stuck at 97% forever; `ProgressHandle` never throttles this one away.
        progress.report(LatheProgress(
            fraction: 1, stage: "encode",
            unitIndex: max(state.frameCount, estimatedFrames),
            unitCount: max(state.frameCount, estimatedFrames)
        ))

        return AudioTranscodeResult(
            output: request.destination,
            outcome: .transcoded,
            source: sourceStream,
            destination: written?.stream,
            inputByteCount: inputByteCount,
            outputByteCount: outputByteCount,
            wallTime: Date().timeIntervalSince(started),
            channels: target.channels,
            metadataItemsWritten: metadata.items.count,
            carriedArtwork: metadata.carriedArtwork,
            droppedChapterCount: max(0, sourceChapters.count - preservedChapters),
            preservedChapterCount: preservedChapters,
            chapterLossReason: sourceChapters.count > preservedChapters ? chapterLossReason : nil
        )
    }

    // MARK: - The target

    /// Everything the encoder needs, resolved against the source so that no
    /// value can exceed it.
    struct Target {
        var sampleRate: Double
        var channels: AppliedChannelPolicy
        /// `nil` for a lossless codec, which has no bitrate to ask for.
        var bitsPerSecond: Int?
        var channelLayout: Data?
    }

    /// Resolves the request against the source **and** against what the encoder
    /// on this machine will accept.
    ///
    /// The second half is not defensive programming for its own sake. An
    /// `AVAssetWriterInput` given settings its encoder cannot honour raises an
    /// Objective-C exception, which Swift cannot catch and which takes the host
    /// application with it — so every value here is run past
    /// ``AudioEncodeSupport`` before it can reach a settings dictionary.
    ///
    /// - Returns: `nil` when the source's sample rate is below anything this
    ///   codec can encode, which is the one case with no honest answer: the
    ///   alternatives are refusing and resampling *upward*, and the second one
    ///   breaks the rule this type is built on.
    static func resolveTarget(_ request: AudioTranscodeRequest, source: AudioStreamInfo) -> Target? {
        // 44.1 kHz stands in for a source whose header does not say; it is the
        // only rate that is never an *upsample* of anything a real file carries
        // at an unreported rate.
        let sourceRate = source.sampleRate > 0 ? source.sampleRate : 44_100
        // The no-upsample rule, in one `min`.
        let asked = min(Double(request.sampleRate ?? Int(sourceRate)), sourceRate)
        guard let rate = AudioEncodeSupport.sampleRate(
            atOrBelow: asked, formatID: request.codec.formatID
        ), rate > 0 else { return nil }

        // Whether the source's channels can be *kept* is a question about the
        // encoder, not about the source: a six-channel layout a WAV is entitled
        // to carry is frequently not one AAC can signal.
        let layout = AudioEncodeSupport.channelLayout(
            forSource: source.channelLayout,
            formatID: request.codec.formatID,
            channels: source.channelCount
        )
        let applied = resolveChannels(
            request.channels,
            sourceChannels: source.channelCount,
            hasLayout: layout != nil
        )
        let bits = request.codec.isLossless
            ? nil
            : bitrate(for: request.quality, channels: applied.outputChannelCount).map {
                AudioEncodeSupport.bitrate(nearest: $0, formatID: request.codec.formatID)
            }
        return Target(
            sampleRate: rate,
            channels: applied,
            bitsPerSecond: bits,
            channelLayout: applied.outputChannelCount == source.channelCount ? layout : nil
        )
    }

    /// The refusal for a source no encoder here can represent.
    static func unencodableRate(_ source: AudioStreamInfo, codec: AudioCodec) -> LatheError {
        .invalidConfiguration(
            reason: "\(source.codecName) at \(Int(source.sampleRate)) Hz is below the lowest rate "
                + "\(codec.codecName) encodes here, and resampling *upward* to reach it would add "
                + "bytes without adding information — which is the one thing this transcoder will "
                + "not do. Leave the file as it is"
        )
    }

    /// Resolves ``ChannelPolicy`` against what the source and the encoder can
    /// actually do.
    ///
    /// Three rules, and the third is the one worth stating: a reduction to
    /// *another* multi-channel layout — 7.1 down to 5.1 — is a mixing decision
    /// with no single right answer, and this package does not invent one. Such a
    /// request becomes a stereo downmix, which is the one remix every decoder
    /// agrees on, and is reported as the downmix it is.
    static func resolveChannels(
        _ policy: ChannelPolicy,
        sourceChannels: Int,
        hasLayout: Bool
    ) -> AppliedChannelPolicy {
        let source = max(1, sourceChannels)
        let asked = policy.resolve(sourceChannels: source)

        if asked >= source {
            guard source > 2 else { return .preserved(channels: source) }
            // An AAC or ALAC encoder cannot be configured for more than two
            // channels without an `AudioChannelLayout`: "six channels" does not
            // say which six, and the encoder refuses rather than guess. Where
            // the source does not carry one, preserving is not on the table.
            return hasLayout
                ? .preserved(channels: source)
                : .downmixedForWantOfALayout(from: source, to: 2)
        }
        if asked <= 2 { return .downmixed(from: source, to: asked) }
        return .downmixed(from: source, to: 2)
    }

    /// The bitrate a ``QualityTarget`` asks for, in bits per second.
    ///
    /// Deliberately arithmetic rather than a mood, for one reason:
    /// ``LossySourceRule`` compares this number against the source's, so a
    /// quality knob that resolved to "whatever the encoder felt like" would make
    /// the whole generation-loss guard unenforceable. Variable-bitrate AAC is
    /// available in AVFoundation and is *not* used here for exactly that.
    ///
    /// ``QualityTarget/quality(_:)`` maps linearly onto 24–96 kbit/s **per
    /// channel**, so for stereo:
    ///
    /// | quality | per channel | stereo |
    /// |--------:|------------:|-------:|
    /// | 0.0     | 24 kbit/s   | 48 kbit/s  |
    /// | 0.25    | 42 kbit/s   | 84 kbit/s  |
    /// | 0.5     | 60 kbit/s   | 120 kbit/s |
    /// | 0.75    | 78 kbit/s   | 156 kbit/s |
    /// | 1.0     | 96 kbit/s   | 192 kbit/s |
    ///
    /// Per channel rather than per file because that is how an AAC encoder
    /// spends bits: 128 kbit/s is generous for stereo and starves 5.1.
    ///
    /// - Returns: `nil` for ``QualityTarget/lossless``, which has no bitrate.
    public static func bitrate(for quality: QualityTarget, channels: Int) -> Int? {
        let channels = max(1, channels)
        switch quality {
        case let .quality(value):
            let clamped = min(max(value, 0), 1)
            let perChannel = (24_000 + clamped * (96_000 - 24_000)) / 1_000
            return Int(perChannel.rounded()) * 1_000 * channels
        case let .averageBitrate(bits):
            return max(1, bits)
        case .lossless:
            return nil
        case .constantQualityFactor:
            // Refused in `validate(_:container:)` before anything reaches here.
            return nil
        }
    }

    // MARK: - The rule

    static func skipReason(
        _ request: AudioTranscodeRequest,
        source: AudioStreamInfo,
        target: Target
    ) -> AudioSkipReason? {
        // A lossless source is where re-encoding actually wins, and the only
        // place a lossy target is defensible. No rule stands in its way.
        guard source.isLossy else { return nil }

        if case .allow = request.lossySources { return nil }

        if request.codec.isLossless {
            return .losslessTargetForLossySource(sourceCodec: source.codecName)
        }

        switch request.lossySources {
        case .never:
            return .lossySourceRefusedByRule
        case .allow:
            return nil
        case let .requireSavings(fraction):
            let required = min(max(fraction, 0), 1)
            guard let sourceBitrate = source.bitsPerSecond, sourceBitrate > 0 else {
                // No way to prove a saving against an unknown number, and
                // guessing is how the trap is sprung.
                return .lossySourceWithUnknownBitrate
            }
            guard let targetBitrate = target.bitsPerSecond else { return nil }
            guard Double(targetBitrate) <= Double(sourceBitrate) * required else {
                return .lossySourceWithoutMeaningfulSavings(
                    sourceBitsPerSecond: sourceBitrate,
                    targetBitsPerSecond: targetBitrate,
                    requiredFraction: required
                )
            }
            return nil
        }
    }

    // MARK: - Settings

    /// What to decode the source into.
    ///
    /// Float for AAC, which is what every AAC encoder wants anyway. **Integer
    /// for Apple Lossless**, because ALAC is an integer codec: handing it float
    /// samples asks the converter for a float-to-integer rounding step that
    /// nothing in the chain is obliged to make bit-exact, and a lossless codec
    /// fed through a lossy conversion is a contradiction that nothing later
    /// would report.
    static func decodeSettings(for codec: AudioCodec, source: AudioStreamInfo) -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        switch codec {
        case .aac:
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
        case .appleLossless:
            // 32-bit signed integer regardless of the source's depth. Every
            // depth ALAC accepts (16, 20, 24, 32) left-shifts into it exactly,
            // and `AVEncoderBitDepthHintKey` shifts it back — so a 16-bit source
            // round-trips bit-for-bit while a 24-bit one is not silently
            // truncated to fit a narrower decode buffer.
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = false
        }
        _ = source
        return settings
    }

    static func encodeSettings(
        _ request: AudioTranscodeRequest,
        target: Target,
        sourceFormat: CMFormatDescription?,
        source: AudioStreamInfo
    ) -> [String: Any] {
        var settings: [String: Any] = [
            AVSampleRateKey: target.sampleRate,
            AVNumberOfChannelsKey: target.channels.outputChannelCount,
        ]
        settings[AVFormatIDKey] = request.codec.formatID
        switch request.codec {
        case .aac:
            if let bitrate = target.bitsPerSecond { settings[AVEncoderBitRateKey] = bitrate }
        case .appleLossless:
            settings[AVEncoderBitDepthHintKey] = alacBitDepthHint(for: source, format: sourceFormat)
        }
        // Required above stereo, meaningless below it, wrong to carry when the
        // channel count changed, and — the reason it is not simply the source's
        // — **fatal** when it is a layout this encoder does not accept. See
        // ``AudioEncodeSupport``.
        if target.channels.outputChannelCount > 2, let layout = target.channelLayout {
            settings[AVChannelLayoutKey] = layout
        }
        return settings
    }

    /// The bit depth to tell the ALAC encoder its material came from.
    ///
    /// Read from the source where the source says: an uncompressed track states
    /// it in its ASBD, and a *compressed* lossless track — ALAC or FLAC — states
    /// it in the format flags instead, which is the case a naive reading of
    /// `mBitsPerChannel` gets wrong by reporting zero. 16 is the fallback,
    /// because it is the depth of every CD-derived file and the one that cannot
    /// make a lower-depth source larger.
    static func alacBitDepthHint(for source: AudioStreamInfo, format: CMFormatDescription?) -> Int {
        if let depth = source.bitDepth, [16, 20, 24, 32].contains(depth) { return depth }
        guard let format,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return 16 }
        // ALAC and FLAC both encode the source depth in the low bits of
        // `mFormatFlags`, with the same 1...4 numbering.
        switch asbd.mFormatFlags {
        case 1: return 16
        case 2: return 20
        case 3: return 24
        case 4: return 32
        default: return 16
        }
    }

    // MARK: - Validation

    /// The container named by the destination's extension.
    ///
    /// Refused rather than guessed, and — for the formats this package is asked
    /// for most and cannot write — refused **by name**, so the answer is "no,
    /// and here is why" rather than a generic complaint about an extension.
    static func container(for destination: URL) throws -> AudioContainer {
        let ext = destination.pathExtension.lowercased()
        if let container = AudioContainer(fileExtension: ext) { return container }

        switch ext {
        case "opus", "ogg", "oga", "webm":
            throw LatheError.unsupportedOnThisPlatform(
                feature: "Opus encoding (\"\(ext)\") — AVFoundation decodes Opus and ships no "
                    + "encoder for it, so nothing on this platform can write one. This package "
                    + "will not quietly put AAC in a file you asked to be Opus; name a .m4a "
                    + "destination if AAC is acceptable"
            )
        case "mp3":
            throw LatheError.unsupportedOnThisPlatform(
                feature: "MP3 encoding — AVFoundation reads MP3 everywhere and writes it nowhere; "
                    + "name a .m4a destination"
            )
        case "flac":
            throw LatheError.unsupportedOnThisPlatform(
                feature: "FLAC encoding — AVFoundation decodes FLAC (so a FLAC source is a fine "
                    + "input) but has no file type to mux it into; use .m4a with "
                    + "AudioCodec.appleLossless for a lossless output"
            )
        case "wav", "wave", "aif", "aiff", "aifc":
            throw LatheError.invalidConfiguration(
                reason: "\".\(ext)\" holds uncompressed PCM, and this transcoder compresses. Use "
                    + ".m4a with AudioCodec.appleLossless for a lossless result that is smaller "
                    + "than the source rather than identical to it"
            )
        default:
            throw LatheError.invalidConfiguration(
                reason: "no audio container is named by the extension "
                    + "\"\(destination.pathExtension)\"; use m4a, mp4 or caf"
            )
        }
    }

    static func validate(_ request: AudioTranscodeRequest, container: AudioContainer) throws {
        switch (request.codec, request.quality) {
        case (.appleLossless, .lossless):
            break
        case (.appleLossless, _):
            throw LatheError.invalidConfiguration(
                reason: "Apple Lossless has no quality knob — it reproduces its input exactly, or "
                    + "it is not lossless. Pass QualityTarget.lossless with "
                    + "AudioCodec.appleLossless, or ask for AudioCodec.aac if a quality is what "
                    + "was meant"
            )
        case (.aac, .lossless):
            throw LatheError.invalidConfiguration(
                reason: "QualityTarget.lossless means \"reproduce the input exactly\", and AAC "
                    + "cannot. Use AudioCodec.appleLossless for that, or ask for a "
                    + ".quality(_) — note that quality 1.0 is still lossy"
            )
        case (.aac, .constantQualityFactor):
            throw LatheError.invalidConfiguration(
                reason: "QualityTarget.constantQualityFactor is a VideoToolbox rate control and "
                    + "has no audio equivalent; use .quality(_) or .averageBitrate(_), both of "
                    + "which resolve to a bitrate the lossy-source rule can compare against"
            )
        case (.aac, let quality):
            if case let .averageBitrate(bits) = quality, bits <= 0 {
                throw LatheError.invalidConfiguration(
                    reason: "a target bitrate must be positive"
                )
            }
        }

        if let rate = request.sampleRate, rate <= 0 {
            throw LatheError.invalidConfiguration(reason: "a target sample rate must be positive")
        }
        if case let .atMost(count) = request.channels, count <= 0 {
            throw LatheError.invalidConfiguration(reason: "a channel count must be positive")
        }
        _ = container
    }

    // MARK: - Files

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

// MARK: - Container file types

extension AudioContainer {
    var fileType: AVFileType {
        switch self {
        case .m4a: .m4a
        case .mp4: .mp4
        case .caf: .caf
        }
    }
}

// MARK: - Shared state

/// The little the pump accumulates.
private final class TranscodeState: @unchecked Sendable {
    /// Sample frames handed to the encoder. Touched only on the pump's queue.
    var frameCount: UInt64 = 0

    private let lock = NSLock()
    private var latest: CMTime = .invalid

    /// The end of the last buffer appended, which is where the session is
    /// ended — so the output's duration is what was actually written rather than
    /// what the source claimed.
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
/// That shape appears to work and deadlocks as soon as a writer has two inputs:
/// one input goes not-ready part way through and never comes back, while the
/// writer's status stays `.writing` and reports no error at all. Polling is not
/// how the writer expects to be driven — `requestMediaDataWhenReady(on:using:)`
/// is, and with one pump per input the writer schedules them and does its own
/// interleaving.
///
/// This transcoder has exactly one input, so it could get away with polling.
/// It does not, for two reasons: the hazard is completely silent when it does
/// bite — nothing fails, the job simply stops — and the day a second input is
/// added here (chapters, most likely) is the day the polling version would start
/// hanging for reasons no stack trace explains.
///
/// (The video module and the test-support fixture writer carry the same
/// machinery. It is duplicated rather than shared because the linking contract
/// keeps the modules apart and nothing outside the package may import the
/// fixtures — and a hazard this quiet is worth stating three times.)
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

    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()

                let queue = DispatchQueue(label: "dev.lathe.audio.\(label)")
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
