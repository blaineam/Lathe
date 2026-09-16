#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Foundation
import LatheCore

/// Puts subtitle tracks into a film, takes them out again, and lists them —
/// **without re-encoding a single video or audio sample.**
///
/// ## Why a track inside the file, and not a sidecar
///
/// A `.srt` beside the film works in VLC and Infuse and does nothing in
/// Apple's TV app, QuickTime Player or the Files app. For anyone using those,
/// "add subtitles" means a track inside the container or it means nothing.
///
/// ## Why `AVAssetWriter`, and not a composition and a passthrough export
///
/// The composition route looks shorter — ``MetadataWriter`` uses a passthrough
/// export for exactly this kind of rewrite — and it does not reach:
///
/// - **A composition track copies from an asset.** There is no asset holding
///   the new subtitles, so one would have to be written first, with an
///   `AVAssetWriter` — at which point the writer is doing the hard part anyway.
/// - **An export session decides the track layout itself.** It does not expose
///   a track's language tag, its title, its alternate group or which subtitle
///   is the default, and those four are precisely what make a subtitle menu
///   read "English, Français (Forced)" instead of "Unknown, Unknown".
///
/// So every track is copied with an `AVAssetReaderTrackOutput` and an
/// `AVAssetWriterInput` that both have `outputSettings: nil` — the passthrough
/// contract `StreamMuxer` in LatheFetch relies on — and the subtitle tracks are
/// written beside them as `tx3g` samples (see ``TimedTextSample`` for why that
/// format).
///
/// ## What makes a track show up in a subtitle menu
///
/// Learned by a spike before this type existed, and each one is a way to write
/// a file that contains subtitles nobody can turn on:
///
/// 1. **The media type must be `.subtitle`.** The same `tx3g` bytes in a
///    `.text` track are a chapter list or a caption nobody is offered.
/// 2. **The tracks must share an alternate group**, which is what
///    `AVAssetWriterInputGroup` writes. It is also how "off" works: a group
///    with no default input is a menu whose initial choice is none.
/// 3. **The language must be an ISO 639-2 code**, with the BCP 47 tag beside
///    it — see ``SubtitleLanguage``.
/// 4. **Every full subtitle track also yields a "Forced" option.** AVFoundation
///    synthesises, beside each track that is not itself forced, an option that
///    shows only that track's forced samples. So two languages make four
///    options, and a caller counting options to check its work has to count the
///    ones without `containsOnlyForcedSubtitles`.
/// 5. **The `selectionFollower` association is refused, and that is fine.**
///    `canAddTrackAssociation` answers `false` for it on current systems. The
///    obvious reading is that subtitles cannot be attached; in fact the track
///    still appears in the asset's legible selection group, which is what a
///    menu is built from. The association is not attempted.
///
/// ## What else is carried
///
/// Every video, audio, subtitle and closed-caption track, with its language,
/// transform, enabled state and track metadata; the file's own metadata; and
/// the chapter list, which is rebuilt through ``LatheCore/ChapterTrack``
/// because a chapter track copied as a plain text track loses the association
/// that makes it a chapter list. Anything the destination container refuses is
/// named in ``SubtitleInjectionResult/droppedTracks`` rather than lost quietly.
///
/// The copying is ``TrackRemux``, shared with ``ChapterWriter``; what is here
/// is only what is particular to subtitles.
public struct SubtitleMuxer: Sendable {

    public init() {}

    /// The containers subtitles can be written into, by extension.
    public static let supportedExtensions: [String: AVFileType] = [
        "mp4": .mp4, "m4v": .m4v, "mov": .mov, "qt": .mov,
    ]

    // MARK: - Injecting

    /// Writes `source` to `destination` with `tracks` added as subtitle tracks.
    ///
    /// - Parameters:
    ///   - tracks: the subtitles to add, one track each. Several languages in
    ///     one call is the ordinary case.
    ///   - existing: what to do with subtitle tracks already in the file.
    ///   - progress: reported against the film's duration under the stage
    ///     `"subtitles"`; cancellation is honoured at every sample.
    /// - Throws: ``SubtitleError`` for anything about the subtitles or the
    ///   container, ``LatheCore/LatheError/cancelled(atUnit:)`` on
    ///   cancellation. `destination` is untouched unless the write succeeds.
    @discardableResult
    public func inject(
        _ tracks: [SubtitleTrackSource],
        into source: URL,
        writingTo destination: URL,
        existing: ExistingSubtitlePolicy = .keep,
        progress: ProgressHandle = .ignoring()
    ) async throws -> SubtitleInjectionResult {
        try MetaFiles.requireReadableFile(at: source)
        guard source.standardizedFileURL.resolvingSymlinksInPath()
                != destination.standardizedFileURL.resolvingSymlinksInPath() else {
            throw SubtitleError.destinationIsSource(destination.lastPathComponent)
        }
        guard let fileType = Self.supportedExtensions[destination.pathExtension.lowercased()] else {
            throw SubtitleError.unsupportedContainer(
                destination.pathExtension.isEmpty ? destination.lastPathComponent : "." + destination.pathExtension
            )
        }
        guard !tracks.isEmpty || existing != .keep else {
            throw LatheError.invalidConfiguration(reason: "no subtitle tracks were given to add")
        }
        // Every language is checked before anything is written, so a typo in
        // the third track does not cost a full copy of the film.
        let languages = try tracks.map { try SubtitleLanguage($0.language) }

        let asset = AVURLAsset(url: source)
        let sourceTracks: [AVAssetTrack]
        let duration: CMTime
        do {
            sourceTracks = try await asset.load(.tracks)
            duration = try await asset.load(.duration)
        } catch {
            throw LatheError.readFailed(
                path: source.lastPathComponent, reason: (error as NSError).localizedDescription
            )
        }
        guard let firstVideo = sourceTracks.first(where: { $0.mediaType == .video }) else {
            throw SubtitleError.noVideoTrack(source.lastPathComponent)
        }
        let videoSize = await Self.displaySize(of: firstVideo)
        let durationMS = max(0, Int64((duration.seconds * 1000).rounded(.down)))

        // The subtitle samples are built before any writing starts, so a set of
        // cues that cannot be placed fails fast and leaves nothing behind.
        var prepared: [PreparedSubtitles] = []
        for (source, language) in zip(tracks, languages) {
            prepared.append(try Self.prepare(source, language: language, videoSize: videoSize,
                                             durationMS: durationMS))
        }

        let scratch = TrackRemux.scratchURL(beside: destination, prefix: ".lathe-subtitles-")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let outcome: WriteOutcome
        do {
            outcome = try await write(
                asset: asset, duration: duration,
                prepared: prepared, existing: existing, fileType: fileType,
                to: scratch, progress: progress
            )
        } catch let failure as TrackRemux.Failure {
            throw SubtitleError.muxFailed(stage: failure.stage, reason: failure.reason)
        }
        try TrackRemux.moveIntoPlace(scratch, at: destination)

        let written = try await subtitleTracks(in: destination)
        let added = Array(written.suffix(prepared.count))
        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        return SubtitleInjectionResult(
            output: destination,
            addedTracks: added,
            cuesWritten: prepared.map(\.cueCount),
            cuesOutsideFilm: prepared.map(\.droppedCount),
            keptSubtitleTrackCount: outcome.kept,
            removedSubtitleTrackCount: outcome.removed,
            preservedChapterCount: outcome.chapters,
            droppedTracks: outcome.dropped,
            outputByteCount: UInt64(bytes)
        )
    }

    // MARK: - Listing and extracting

    /// The subtitle tracks in a file, in track order.
    public func subtitleTracks(in url: URL) async throws -> [SubtitleTrackInfo] {
        try MetaFiles.requireReadableFile(at: url)
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .subtitle)
        } catch {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: (error as NSError).localizedDescription)
        }
        var out: [SubtitleTrackInfo] = []
        for track in tracks.sorted(by: { $0.trackID < $1.trackID }) {
            out.append(await Self.info(for: track))
        }
        return out
    }

    /// One subtitle track's cues. `trackID` defaults to the first subtitle
    /// track.
    ///
    /// Empty samples — the gap fillers every MP4 subtitle track has — are
    /// skipped, and consecutive identical samples are joined, so a track
    /// written from a list of cues reads back as that list.
    public func extractCues(from url: URL, trackID: Int32? = nil) async throws -> [SubtitleCue] {
        try MetaFiles.requireReadableFile(at: url)
        let asset = AVURLAsset(url: url)
        let track: AVAssetTrack
        if let trackID {
            guard let found = try? await asset.loadTrack(withTrackID: CMPersistentTrackID(trackID)),
                  found.mediaType == .subtitle || found.mediaType == .text
            else { throw SubtitleError.trackNotFound(trackID: trackID) }
            track = found
        } else {
            guard let first = (try? await asset.loadTracks(withMediaType: .subtitle))?
                .min(by: { $0.trackID < $1.trackID })
            else { throw SubtitleError.trackNotFound(trackID: 0) }
            track = first
        }

        let format = (try? await track.load(.formatDescriptions))?.first
        let subtype = format.map { Self.fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "none"
        let decode: ([UInt8]) -> (String, [SubtitleStyleRun])?
        switch subtype {
        case "tx3g", "text": decode = TimedTextSample.decodeTx3g
        case "wvtt": decode = TimedTextSample.decodeWebVTT
        default: throw SubtitleError.unreadableTrack(trackID: track.trackID, format: subtype)
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: (error as NSError).localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {
            throw SubtitleError.unreadableTrack(trackID: track.trackID, format: subtype)
        }
        reader.add(output)
        guard reader.startReading() else {
            throw LatheError.readFailed(
                path: url.lastPathComponent,
                reason: reader.error.map { ($0 as NSError).localizedDescription } ?? "the reader would not start"
            )
        }

        var cues: [SubtitleCue] = []
        while let buffer = output.copyNextSampleBuffer() {
            for sample in Self.samples(in: buffer) {
                guard let (text, styles) = decode(sample.bytes) else { continue }
                let start = sample.start
                let end = sample.start + sample.duration
                if var last = cues.last, abs(last.endSeconds - start) < 0.000_5,
                   last.text == text, last.styles == styles {
                    last.endSeconds = end
                    cues[cues.count - 1] = last
                } else {
                    cues.append(SubtitleCue(startSeconds: start, endSeconds: end, text: text, styles: styles))
                }
            }
        }
        if reader.status == .failed {
            throw LatheError.readFailed(
                path: url.lastPathComponent,
                reason: reader.error.map { ($0 as NSError).localizedDescription } ?? "the reader failed"
            )
        }
        return cues
    }

    /// One subtitle track as SubRip text.
    public func extractSubRip(from url: URL, trackID: Int32? = nil) async throws -> String {
        SubtitleSerializer.subRip(try await extractCues(from: url, trackID: trackID))
    }

    // MARK: - Preparing samples

    struct PreparedSubtitles: @unchecked Sendable {
        let language: SubtitleLanguage
        let source: SubtitleTrackSource
        let format: CMFormatDescription
        let samples: [(payload: Data, startMS: Int64, durationMS: Int64)]
        let cueCount: Int
        let droppedCount: Int
    }

    /// The track's samples: cues flattened so one shows at a time, clipped to
    /// the film, with an empty sample in every gap and one to the end — so the
    /// track is as long as the film, and nothing lingers past its cue.
    static func prepare(
        _ source: SubtitleTrackSource, language: SubtitleLanguage, videoSize: CGSize, durationMS: Int64
    ) throws -> PreparedSubtitles {
        guard let format = TimedTextSample.formatDescription(videoSize: videoSize, forced: source.isForced) else {
            throw SubtitleError.muxFailed(
                stage: "building the track description",
                reason: "this system would not build a tx3g subtitle description"
            )
        }
        let fontSize = TimedTextSample.fontSize(forHeight: videoSize.height)
        let flat = source.cues.flattenedForTimedText()
        guard !flat.isEmpty else { throw SubtitleError.noCues }

        var samples: [(payload: Data, startMS: Int64, durationMS: Int64)] = []
        var cursor: Int64 = 0
        var written = 0
        var dropped = 0
        for cue in flat {
            // Milliseconds, the resolution both text formats have. Rounding
            // rather than truncating, for the reason ``SubtitleSerializer``
            // gives.
            var start = Int64((cue.startSeconds * 1000).rounded())
            let end = min(Int64((cue.endSeconds * 1000).rounded()), durationMS)
            start = max(start, cursor)
            guard end > start else {
                dropped += 1
                continue
            }
            if start > cursor {
                samples.append((TimedTextSample.emptyPayload, cursor, start - cursor))
            }
            samples.append((TimedTextSample.payload(text: cue.text, styles: cue.styles, fontSize: fontSize),
                            start, end - start))
            cursor = end
            written += 1
        }
        guard written > 0 else {
            throw SubtitleError.cuesOutsideFilm(language: source.language)
        }
        if cursor < durationMS {
            samples.append((TimedTextSample.emptyPayload, cursor, durationMS - cursor))
        }
        return PreparedSubtitles(
            language: language, source: source, format: format,
            samples: samples, cueCount: written, droppedCount: dropped
        )
    }

    // MARK: - Writing

    private struct WriteOutcome {
        var kept = 0
        var removed = 0
        var chapters = 0
        var dropped: [String] = []
    }

    /// The subtitle-specific part of the remux: which existing tracks stay,
    /// the new tracks and their pumps, and which one is the default. The
    /// copying, the chapter list and the writer are ``TrackRemux``'s.
    private func write(
        asset: AVURLAsset,
        duration: CMTime,
        prepared: [PreparedSubtitles],
        existing: ExistingSubtitlePolicy,
        fileType: AVFileType,
        to url: URL,
        progress: ProgressHandle
    ) async throws -> WriteOutcome {
        let remux = try TrackRemux(
            asset: asset, duration: duration, writingTo: url, fileType: fileType,
            metadata: (try? await asset.load(.metadata)) ?? [],
            stage: "subtitles", progress: progress
        )

        let newCodes = Set(prepared.map(\.language.iso639_2))
        let newTags = Set(prepared.compactMap(\.language.bcp47))

        // MARK: Passthrough tracks
        try await remux.copyTracks { track in
            switch existing {
            case .keep:
                return true
            case .removeAll:
                return false
            case .replaceSameLanguage:
                let code = (try? await track.load(.languageCode)) ?? nil
                let tag = (try? await track.load(.extendedLanguageTag)) ?? nil
                return !(code.map(newCodes.contains) == true || tag.map(newTags.contains) == true)
            }
        }
        guard !remux.videoInputs.isEmpty else {
            throw TrackRemux.Failure(
                stage: "copying the video",
                reason: "\(fileType.rawValue) will not hold this file's video track"
            )
        }

        // MARK: Chapters
        let chapters = await ChapterTrack.read(from: asset)
        let chapterAttachment = remux.attachChapters(chapters)
        var notes: [String] = []
        if !chapters.isEmpty, let reason = chapterAttachment.reason {
            notes.append("\(chapters.count) chapters: \(reason)")
        }

        // MARK: New subtitle tracks
        let writer = remux.writer
        var defaultNew: AVAssetWriterInput?
        for track in prepared {
            let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: track.format)
            input.expectsMediaDataInRealTime = false
            input.languageCode = track.language.iso639_2
            if let tag = track.language.bcp47 { input.extendedLanguageTag = tag }
            input.metadata = Self.trackMetadata(for: track.source)
            input.marksOutputTrackAsEnabled = track.source.isDefault
            guard writer.canAdd(input) else {
                throw SubtitleError.muxFailed(
                    stage: "adding the \(track.source.language) track",
                    reason: "\(fileType.rawValue) refused a subtitle track"
                )
            }
            if track.source.isDefault, defaultNew == nil { defaultNew = input }

            let format = track.format
            let label = "subtitles \(track.source.language)"
            var remaining = track.samples[...]
            let pump = MetaWriterPump(input: input, label: label) {
                guard let next = remaining.popFirst() else { return false }
                guard let buffer = TimedTextSample.sampleBuffer(
                    payload: next.payload,
                    start: CMTime(value: next.startMS, timescale: 1000),
                    duration: CMTime(value: next.durationMS, timescale: 1000),
                    format: format
                ) else {
                    throw SubtitleError.muxFailed(stage: "building a sample for \(label)",
                                                  reason: "Core Media would not build the sample")
                }
                guard input.append(buffer) else {
                    throw SubtitleError.muxFailed(
                        stage: "writing \(label)",
                        reason: writer.error.map { ($0 as NSError).localizedDescription }
                            ?? "the writer rejected a sample"
                    )
                }
                try progress.checkCancellation()
                return true
            }
            remux.add(input, legible: true, enabled: track.source.isDefault, pump: pump)
        }

        // MARK: Alternate groups
        //
        // One group for the subtitles, kept and new together, or the menu
        // would offer two unrelated sets. A new track marked default wins over
        // whichever kept track the source had switched on.
        remux.groupTracks(legibleDefault: defaultNew)

        // MARK: Run
        let written = try await remux.run()
        return WriteOutcome(
            kept: remux.keptSubtitleCount,
            removed: remux.removedSubtitleCount,
            chapters: written.chaptersWritten,
            dropped: remux.dropped + notes
        )
    }

    // MARK: - Helpers

    /// A track's title, and the accessibility characteristics that make an SDH
    /// track say so in a player's menu.
    ///
    /// Both are given as QuickTime user-data items, and the writer translates
    /// them for an MP4 — `udta/tnam` becomes the 3GPP `titl` box, `udta/tagc`
    /// becomes `uiso/tagc` — so one spelling serves every container.
    ///
    /// **No `dataType` is set, deliberately.** Setting the tagged
    /// characteristic's data type to UTF-8 — the obvious, explicit thing — makes
    /// the writer drop the item without a word: the file is written, the track
    /// has its title, and the SDH marking is simply not there.
    static func trackMetadata(for source: SubtitleTrackSource) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        if let title = source.title, !title.isEmpty {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeUserDataTrackName
            item.value = title as NSString
            items.append(item)
        }
        if source.isHearingImpaired {
            for characteristic in [AVMediaCharacteristic.transcribesSpokenDialogForAccessibility,
                                   .describesMusicAndSoundForAccessibility] {
                let item = AVMutableMetadataItem()
                item.identifier = .quickTimeUserDataTaggedCharacteristic
                item.value = characteristic.rawValue as NSString
                items.append(item)
            }
        }
        return items
    }

    static func info(for track: AVAssetTrack) async -> SubtitleTrackInfo {
        let format = (try? await track.load(.formatDescriptions))?.first
        let subtype = format.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "none"
        let code = ((try? await track.load(.languageCode)) ?? nil) ?? "und"
        let tag = (try? await track.load(.extendedLanguageTag)) ?? nil
        let characteristics = (try? await track.load(.mediaCharacteristics)) ?? []
        let metadata = (try? await track.load(.metadata)) ?? []
        var title: String?
        // `udta/tnam` in a QuickTime file, the 3GPP `uiso/titl` in an MP4; the
        // latter has no identifier constant but does carry the common title key.
        for item in metadata where item.identifier == .quickTimeUserDataTrackName
            || item.commonKey == .commonKeyTitle {
            if let value = try? await item.load(.stringValue) {
                title = value
                break
            }
        }
        var forced = characteristics.contains(.containsOnlyForcedSubtitles)
        if !forced, let format, subtype == "tx3g",
           let flags = CMFormatDescriptionGetExtension(
               format, extensionKey: kCMTextFormatDescriptionExtension_DisplayFlags
           ) as? NSNumber {
            forced = flags.uint32Value & TimedTextSample.allSamplesForced != 0
        }
        return SubtitleTrackInfo(
            trackID: track.trackID,
            languageCode: code,
            extendedLanguageTag: tag,
            title: title,
            codec: subtype,
            isEnabled: (try? await track.load(.isEnabled)) ?? false,
            isForced: forced,
            isHearingImpaired: characteristics.contains(.transcribesSpokenDialogForAccessibility),
            isExtractable: subtype == "tx3g" || subtype == "wvtt"
        )
    }

    private static func displaySize(of track: AVAssetTrack) async -> CGSize {
        let natural = (try? await track.load(.naturalSize)) ?? CGSize(width: 1920, height: 1080)
        let transform = (try? await track.load(.preferredTransform)) ?? .identity
        let applied = natural.applying(transform)
        let size = CGSize(width: abs(applied.width), height: abs(applied.height))
        return size.width > 0 && size.height > 0 ? size : CGSize(width: 1920, height: 1080)
    }

    struct TimedSample {
        let bytes: [UInt8]
        let start: Double
        let duration: Double
    }

    /// Each sample in a buffer, with its own timing and bytes. A reader may
    /// hand several samples back in one buffer, and treating that as one
    /// sample reads the first cue's length prefix and drops the rest.
    static func samples(in buffer: CMSampleBuffer) -> [TimedSample] {
        let count = CMSampleBufferGetNumSamples(buffer)
        guard count > 0, let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        let total = CMBlockBufferGetDataLength(block)
        var all = [UInt8](repeating: 0, count: total)
        guard total > 0, all.withUnsafeMutableBytes({
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: $0.baseAddress!)
        }) == noErr else { return [] }

        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        var timingCount: CMItemCount = 0
        _ = CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &timingCount
        )
        var sizes = [Int](repeating: 0, count: count)
        var sizeCount: CMItemCount = 0
        _ = CMSampleBufferGetSampleSizeArray(buffer, entryCount: count, arrayToFill: &sizes, entriesNeededOut: &sizeCount)
        if sizeCount == 1, count > 1 { sizes = [Int](repeating: sizes[0], count: count) }
        if sizeCount == 0 { sizes = count == 1 ? [total] : [] }

        var out: [TimedSample] = []
        var offset = 0
        var clock = timings.first?.presentationTimeStamp ?? .zero
        for index in 0..<min(count, sizes.count) {
            let size = sizes[index]
            guard size >= 0, offset + size <= total else { break }
            let timing = index < Int(timingCount) ? timings[index] : (timingCount == 1 ? timings[0] : CMSampleTimingInfo())
            // One timing entry for many samples means they share a duration
            // and follow one another.
            let start = (timingCount == Int(count) && timing.presentationTimeStamp.isValid)
                ? timing.presentationTimeStamp : clock
            let length = timing.duration.isValid ? timing.duration : .zero
            out.append(TimedSample(bytes: Array(all[offset..<(offset + size)]),
                                   start: start.seconds, duration: length.seconds))
            clock = CMTimeAdd(start, length)
            offset += size
        }
        return out
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(decoding: bytes, as: UTF8.self)
    }

}

// MARK: - Public types

/// One subtitle track to add.
public struct SubtitleTrackSource: Sendable, Equatable {
    public var cues: [SubtitleCue]

    /// A BCP 47 tag or ISO 639 code. Validated before anything is written.
    public var language: String

    /// A name for the track, which VLC, Infuse and Plex show as the track name.
    ///
    /// Apple's players name an option from its language and characteristics.
    /// AVFoundation has been seen to put this title in front of that name
    /// ("Commentary - English") and also, for the same file, not to — so a
    /// menu entry should never depend on it.
    public var title: String?

    /// Whether the track is on when playback starts. Off by default, as a
    /// viewer expects subtitles to be.
    public var isDefault: Bool

    /// Forced subtitles: only the lines a viewer needs regardless — signs,
    /// foreign-language dialogue — shown even with subtitles off.
    public var isForced: Bool

    /// Subtitles for the deaf and hard of hearing, which describe sound as well
    /// as dialogue. Written as accessibility characteristics, which is how
    /// Apple's players come to label the option "SDH".
    public var isHearingImpaired: Bool

    public init(
        cues: [SubtitleCue],
        language: String,
        title: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        isHearingImpaired: Bool = false
    ) {
        self.cues = cues
        self.language = language
        self.title = title
        self.isDefault = isDefault
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
    }

    /// A track from a SubRip or WebVTT file's bytes.
    public init(
        parsing data: Data,
        format: SubtitleFormat? = nil,
        language: String,
        title: String? = nil,
        recovery: SubtitleParser.Recovery = .strict
    ) throws {
        let parsed = try SubtitleParser.parse(data, format: format, recovery: recovery)
        self.init(cues: parsed.cues, language: language, title: title)
    }
}

/// What to do with subtitle tracks the file already has.
public enum ExistingSubtitlePolicy: Sendable, Equatable {
    /// Keep them all, beside the new ones.
    case keep
    /// Remove any whose language matches a track being added — the "this
    /// English track is out of sync, use this one" case.
    case replaceSameLanguage
    /// Remove them all. With no tracks to add, this strips a file's subtitles.
    case removeAll
}

/// A subtitle track in a file.
public struct SubtitleTrackInfo: Sendable, Equatable, Identifiable {
    public var id: Int32 { trackID }
    public var trackID: Int32
    /// The ISO 639-2/T code in the track header.
    public var languageCode: String
    /// The BCP 47 tag, when the file has one.
    public var extendedLanguageTag: String?
    public var title: String?
    /// The sample format: `tx3g`, `wvtt`, or something extraction cannot read.
    public var codec: String
    public var isEnabled: Bool
    public var isForced: Bool
    public var isHearingImpaired: Bool
    /// Whether ``SubtitleMuxer/extractCues(from:trackID:)`` can read it.
    public var isExtractable: Bool
}

/// What an injection produced.
public struct SubtitleInjectionResult: Sendable, Equatable {
    public var output: URL
    /// The tracks that were added, as read back from the written file.
    public var addedTracks: [SubtitleTrackInfo]
    /// Per added track, in the order given: cues written, after overlapping
    /// cues were merged into shared samples.
    public var cuesWritten: [Int]
    /// Per added track: cues that began after the film ended and were left
    /// out. A large number usually means subtitles timed for another release.
    public var cuesOutsideFilm: [Int]
    public var keptSubtitleTrackCount: Int
    public var removedSubtitleTrackCount: Int
    public var preservedChapterCount: Int
    /// Tracks from the source that are not in the output, each with the
    /// reason. Empty for any ordinary MP4 or MOV.
    public var droppedTracks: [String]
    public var outputByteCount: UInt64
}

// MARK: - Pumping

/// Feeds one `AVAssetWriterInput` from its own queue until its source runs out.
///
/// The fourth copy of this machinery in the package — `StreamMuxer`, the video
/// transcoder and the fixture writer carry the others; within LatheMeta it is
/// the only one, driven by ``TrackRemux`` — for the reason
/// `StreamMuxer` gives: polling `isReadyForMoreMediaData` from one thread
/// deadlocks a multi-input writer silently, and a subtitle file always has at
/// least two inputs.
final class MetaWriterPump: @unchecked Sendable {
    private let input: AVAssetWriterInput
    private let label: String
    private var step: () throws -> Bool

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

                let queue = DispatchQueue(label: "dev.lathe.meta.\(label)")
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    do {
                        while !isStopped, input.isReadyForMoreMediaData {
                            if try step() == false {
                                input.markAsFinished()
                                settle(nil)
                                return
                            }
                        }
                        if isStopped {
                            input.markAsFinished()
                            settle(CancellationError())
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

    /// Resumes exactly once: the callback fires again after
    /// `markAsFinished()`, and resuming a continuation twice traps.
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

/// The furthest sample end any input has written.
final class MetaMuxClock: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CMTime = .invalid

    var end: CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return latest.isValid ? latest : nil
    }

    var endSeconds: Double { end?.seconds ?? 0 }

    func observe(end: CMTime) {
        guard end.isValid, end.isNumeric else { return }
        lock.lock()
        if !latest.isValid || end > latest { latest = end }
        lock.unlock()
    }
}
#endif
