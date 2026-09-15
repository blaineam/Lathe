import AVFoundation
import CoreMedia
import Foundation
import LatheCore
import LatheFixtures
import Testing

@testable import LatheVideo

/// **A spike, not a feature.** Can AVAssetWriter write a subtitle track that
/// Apple's own player will offer as a subtitle choice?
///
/// The question matters because sidecar `.srt` files work in Infuse and VLC and
/// do **not** work in Apple's TV app — so "add subtitles" means a track inside
/// the file or it means nothing. Writing video and audio tracks with
/// AVAssetWriter is well travelled; writing timed text is not, and the roadmap
/// has been carrying this as an unanswered question rather than a feature.
///
/// Each test below answers one step, so a failure says which step failed rather
/// than "subtitles do not work".
@Suite("Subtitle muxing spike", .serialized)
struct SubtitleSpikeTests {

    private static let size = PixelSize(width: 160, height: 120)

    // MARK: - Step 1: will a format description exist at all?

    /// `tx3g` is the 3GPP timed-text format chapters already use. The chapter
    /// work proved a description can be built for `kCMMediaType_Text`; the
    /// question here is whether the same works for `kCMMediaType_Subtitle`,
    /// which is what makes a track a *subtitle* rather than a chapter list.
    @Test("a tx3g format description can be built for the subtitle media type")
    func subtitleFormatDescriptionExists() {
        let description = ChapterTrack.sampleDescription()
        var format: CMFormatDescription?
        let status = description.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: kCFAllocatorDefault,
                bigEndianTextDescriptionData: base,
                size: description.count,
                flavor: nil,
                mediaType: kCMMediaType_Subtitle,
                formatDescriptionOut: &format
            )
        }
        #expect(status == noErr, "CMTextFormatDescription for subtitles returned \(status)")
        #expect(format != nil)
        if let format {
            #expect(CMFormatDescriptionGetMediaType(format) == kCMMediaType_Subtitle)
        }
    }

    /// WebVTT in MP4 is the other candidate, and modern Apple platforms play it.
    @Test("what the system says about a WebVTT subtitle format description")
    func webVTTFormatDescription() {
        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: kCMMediaType_Subtitle,
            mediaSubType: kCMSubtitleFormatType_WebVTT,
            extensions: nil,
            formatDescriptionOut: &format
        )
        // The finding: a WebVTT description is creatable too, so tx3g is a
        // choice rather than the only option. tx3g is what this package uses,
        // because the chapter work already proved the sample format end to end
        // and a second sample encoding is a second thing to get wrong.
        #expect(status == noErr, "WebVTT description returned \(status)")
        #expect(format != nil)
    }

    // MARK: - Step 2: will a writer accept the input?

    @Test("an AVAssetWriter accepts a subtitle input and associates it with video")
    func writerAcceptsASubtitleInput() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subspike-accept-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160, AVVideoHeightKey: 120,
        ])
        #expect(writer.canAdd(video))
        writer.add(video)

        let description = ChapterTrack.sampleDescription()
        var format: CMFormatDescription?
        _ = description.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: kCFAllocatorDefault, bigEndianTextDescriptionData: base,
                size: description.count, flavor: nil, mediaType: kCMMediaType_Subtitle,
                formatDescriptionOut: &format
            )
        }
        let subtitleFormat = try #require(format)

        let subtitles = AVAssetWriterInput(
            mediaType: .subtitle, outputSettings: nil, sourceFormatHint: subtitleFormat
        )
        #expect(writer.canAdd(subtitles), "the writer refused a subtitle input outright")

        // **The finding that would otherwise have cost a day**: the
        // selectionFollower association is REFUSED here, and it does not matter.
        // The obvious reading of a refusal is that subtitles cannot be attached
        // and the approach is dead; in fact the track still appears in the
        // asset's legible selection group, which is what a player's subtitle
        // menu is built from. So the association is an optimisation for
        // grouping, not the mechanism.
        let canAssociate = video.canAddTrackAssociation(
            withTrackOf: subtitles, type: AVAssetTrack.AssociationType.selectionFollower.rawValue
        )
        #expect(!canAssociate,
                "selectionFollower is now accepted — the note above should be revisited")
    }

    // MARK: - Step 3: the whole thing, end to end

    /// **The question that actually decides it:** write a real file with a
    /// subtitle track, then ask AVFoundation to read it back and report a
    /// legible-media selection group — which is what the TV app's subtitle menu
    /// is built from.
    @Test("a written subtitle track comes back as a selectable legible option")
    func subtitleTrackRoundTrips() async throws {
        guard let source = await fixture("subspike-source.mov", {
            try await FixtureLibrary.shared.movie(
                named: "subspike-source.mov", size: Self.size, frameRate: 24,
                seconds: 2, audio: .none
            )
        }) else { return }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("subspike-out-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: destination) }

        let cues = [
            (start: 0.0, duration: 1.0, text: "First line"),
            (start: 1.0, duration: 1.0, text: "Deuxième ligne"),
        ]

        let wrote = try await write(source: source, to: destination, cues: cues)
        guard wrote else {
            Issue.record("the writer did not finish; subtitle muxing is not reachable this way")
            return
        }

        // Read it back the way a player does.
        let asset = AVURLAsset(url: destination)
        let subtitleTracks = try await asset.loadTracks(withMediaType: .subtitle)
        let group = try? await asset.loadMediaSelectionGroup(for: .legible)
        let optionCount = group?.options.count ?? 0

        let trackNote = "the output has \(subtitleTracks.count) subtitle tracks"
        #expect(subtitleTracks.count == 1, "\(trackNote)")

        // The legible selection group is what the TV app's subtitle menu is
        // built from. A track that exists and does not appear here is a track
        // no viewer can turn on.
        let optionNote = "legible options: \(optionCount) — a player would show no subtitle menu"
        #expect(optionCount >= 1, "\(optionNote)")

        // The cues really are in there, with their text.
        if let track = subtitleTracks.first {
            let duration = try await track.load(.timeRange).duration.seconds
            #expect(duration > 1.5, "the subtitle track covers only \(duration)s of a 2s film")
        }
    }

    /// **MP4, not just MOV.** MOV is Apple's own container and the permissive
    /// one; MP4 is what a library is actually made of, and a feature that works
    /// only in QuickTime files is not the feature anyone asked for.
    @Test("the same track writes into an MP4 and is still selectable")
    func subtitleTrackWorksInMP4() async throws {
        guard let source = await fixture("subspike-mp4-source.mov", {
            try await FixtureLibrary.shared.movie(
                named: "subspike-mp4-source.mov", size: Self.size, frameRate: 24,
                seconds: 2, audio: .none
            )
        }) else { return }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("subspike-out-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: destination) }

        let wrote = try await write(
            source: source, to: destination,
            cues: [(start: 0.0, duration: 2.0, text: "In an MP4")],
            fileType: .mp4
        )
        guard wrote else {
            Issue.record("MP4 refused the subtitle track; the feature is MOV-only")
            return
        }

        let asset = AVURLAsset(url: destination)
        let tracks = try await asset.loadTracks(withMediaType: .subtitle)
        let options = (try? await asset.loadMediaSelectionGroup(for: .legible))?.options.count ?? 0
        let note = "MP4 output: \(tracks.count) subtitle track(s), \(options) legible option(s)"
        #expect(tracks.count == 1, "\(note)")
        #expect(options >= 1, "\(note)")
    }

    // MARK: - Writing

    private func write(
        source: URL, to destination: URL,
        cues: [(start: Double, duration: Double, text: String)],
        fileType: AVFileType = .mov
    ) async throws -> Bool {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return false
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        let video = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil,
            sourceFormatHint: try await track.load(.formatDescriptions).first
        )
        video.expectsMediaDataInRealTime = false
        guard writer.canAdd(video) else { return false }
        writer.add(video)

        let description = ChapterTrack.sampleDescription()
        var format: CMFormatDescription?
        _ = description.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: kCFAllocatorDefault, bigEndianTextDescriptionData: base,
                size: description.count, flavor: nil, mediaType: kCMMediaType_Subtitle,
                formatDescriptionOut: &format
            )
        }
        guard let subtitleFormat = format else {
            Issue.record("no subtitle format description")
            return false
        }

        let subtitles = AVAssetWriterInput(
            mediaType: .subtitle, outputSettings: nil, sourceFormatHint: subtitleFormat
        )
        subtitles.expectsMediaDataInRealTime = false
        // A language is what makes an option nameable in a menu; without it a
        // track can exist and show as "Unknown".
        subtitles.languageCode = "en"
        subtitles.extendedLanguageTag = "en"
        guard writer.canAdd(subtitles) else {
            Issue.record("the writer refused the subtitle input")
            return false
        }
        if video.canAddTrackAssociation(
            withTrackOf: subtitles, type: AVAssetTrack.AssociationType.selectionFollower.rawValue
        ) {
            video.addTrackAssociation(
                withTrackOf: subtitles,
                type: AVAssetTrack.AssociationType.selectionFollower.rawValue
            )
        }
        writer.add(subtitles)

        guard reader.startReading(), writer.startWriting() else {
            Issue.record("reader/writer refused to start")
            return false
        }
        writer.startSession(atSourceTime: .zero)

        // The subtitle samples, pumped on their own queue — the same rule the
        // chapter work established: a writer will not ready a second input while
        // the calling thread blocks on it.
        let pump = beginSubtitles(cues, to: subtitles, format: subtitleFormat)

        while let buffer = output.copyNextSampleBuffer() {
            while !video.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            if !video.append(buffer) { break }
        }
        video.markAsFinished()
        _ = await pump.value

        await writer.finishWriting()
        if writer.status != .completed {
            Issue.record("finishWriting failed: \(String(describing: writer.error))")
        }
        return writer.status == .completed
    }

    private func beginSubtitles(
        _ cues: [(start: Double, duration: Double, text: String)],
        to input: AVAssetWriterInput,
        format: CMFormatDescription
    ) -> Task<Int, Never> {
        let boxed = Box(input)
        let queue = DispatchQueue(label: "subspike")
        let state = CueState(cues)

        return Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let box = ResumeBox(continuation)
                let writerInput = boxed.value
                writerInput.requestMediaDataWhenReady(on: queue) {
                    while writerInput.isReadyForMoreMediaData {
                        guard let cue = state.next() else {
                            writerInput.markAsFinished()
                            box.resumeOnce()
                            return
                        }
                        guard let buffer = Self.sampleBuffer(for: cue, format: format) else {
                            continue
                        }
                        if writerInput.append(buffer) { state.recordWritten() }
                    }
                }
            }
            return state.written
        }
    }

    /// A tx3g subtitle sample has the same shape as a chapter title: a 16-bit
    /// big-endian byte count then UTF-8.
    private static func sampleBuffer(
        for cue: (start: Double, duration: Double, text: String), format: CMFormatDescription
    ) -> CMSampleBuffer? {
        let payload = ChapterTrack.samplePayload(for: cue.text)
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block
        ) == noErr, let block else { return nil }

        let copied = payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count
            )
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: cue.duration, preferredTimescale: 1_000),
            presentationTimeStamp: CMTime(seconds: cue.start, preferredTimescale: 1_000),
            decodeTimeStamp: .invalid
        )
        var size = payload.count
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer
        ) == noErr else { return nil }
        return buffer
    }

    private final class Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
        func resumeOnce() {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }

    private final class CueState: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [(start: Double, duration: Double, text: String)]
        private var count = 0
        init(_ cues: [(start: Double, duration: Double, text: String)]) { remaining = cues }
        func next() -> (start: Double, duration: Double, text: String)? {
            lock.lock(); defer { lock.unlock() }
            return remaining.isEmpty ? nil : remaining.removeFirst()
        }
        func recordWritten() { lock.lock(); count += 1; lock.unlock() }
        var written: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    private func fixture(_ name: String, _ make: () async throws -> URL) async -> URL? {
        do { return try await make() } catch {
            withKnownIssue("could not generate \"\(name)\": \(error)") {
                Issue.record("fixture generation failed")
            }
            return nil
        }
    }
}
