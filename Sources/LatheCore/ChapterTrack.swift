#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Foundation

/// Reading a file's chapters, and writing them into a new one.
///
/// ## What a chapter actually is
///
/// Not a metadata item. In an MP4-family file a chapter list is a **separate
/// text track** whose samples are the chapter titles, tied to the media track by
/// a track reference of type `chap`. That is why copying an asset's metadata
/// carries titles, artwork and everything else across and loses the chapters
/// entirely: they were never in the metadata.
///
/// So preserving them means three things a metadata copy does not do — muxing a
/// second input, encoding each title as a text sample, and rebuilding the
/// association. This type does all three.
///
/// ## The sample format
///
/// A 3GPP text sample is a 16-bit big-endian length followed by the UTF-8 bytes
/// of the string. Not a C string, not a length-prefixed UTF-16 — and a writer
/// that emits the wrong shape produces a file whose chapter list exists, has the
/// right number of entries at the right times, and shows every title as empty or
/// as mojibake.
public enum ChapterTrack {

    // MARK: - Reading

    /// The chapters an asset declares.
    ///
    /// `loadChapterMetadataGroups` matches against a locale, and a producer's
    /// chapter track carries whatever locale they chose — so every available
    /// locale is asked, and the first that yields anything wins. Asking only for
    /// the device's own language is how a French audiobook reports no chapters
    /// on an English phone.
    public static func read(from asset: AVAsset) async -> [Chapter] {
        let locales = (try? await asset.load(.availableChapterLocales)) ?? []
        var groups: [AVTimedMetadataGroup] = []

        for locale in locales {
            let found = (try? await asset.loadChapterMetadataGroups(
                withTitleLocale: locale, containingItemsWithCommonKeys: [.commonKeyArtwork]
            )) ?? []
            if !found.isEmpty {
                groups = found
                break
            }
        }
        if groups.isEmpty {
            groups = (try? await asset.loadChapterMetadataGroups(
                bestMatchingPreferredLanguages: Locale.preferredLanguages
            )) ?? []
        }

        var chapters: [Chapter] = []
        for group in groups {
            var title = ""
            var artwork: Data?
            for item in group.items {
                switch item.commonKey {
                case .commonKeyTitle:
                    title = ((try? await item.load(.stringValue)) ?? nil) ?? title
                case .commonKeyArtwork:
                    artwork = ((try? await item.load(.dataValue)) ?? nil) ?? artwork
                default:
                    continue
                }
            }
            let range = group.timeRange
            guard range.start.isValid, range.duration.isValid else { continue }
            chapters.append(Chapter(
                startSeconds: range.start.seconds,
                durationSeconds: max(0, range.duration.seconds),
                title: title,
                artwork: artwork
            ))
        }
        return chapters
    }

    // MARK: - Writing

    /// Whether a chapter track could be attached, and if not, why.
    ///
    /// A reason rather than a bare `nil`. Chapters can legitimately fail to
    /// attach — a WAV has nowhere to put them — and a caller told only that it
    /// got none cannot tell an unsupported container from a bug. The string ends
    /// up in ``AudioTranscodeResult`` for exactly that reason.
    public enum Attachment {
        case attached(AVAssetWriterInput)
        case refused(reason: String)

        public var input: AVAssetWriterInput? {
            if case .attached(let input) = self { return input }
            return nil
        }

        public var reason: String? {
            if case .refused(let reason) = self { return reason }
            return nil
        }
    }

    /// A chapter text input attached to `writer` and associated with `media`.
    ///
    /// Refusal is not a failure. A WAV has nowhere to put a chapter track, and
    /// failing the whole transcode over it would be worse than producing the
    /// file the caller asked for and saying what was lost.
    public static func makeInput(
        for chapters: [Chapter],
        writer: AVAssetWriter,
        associatedWith media: AVAssetWriterInput
    ) -> Attachment {
        guard !chapters.isEmpty else { return .refused(reason: "the source has no chapters") }
        guard let format = textFormatDescription() else {
            return .refused(reason: "this system would not build a tx3g format description")
        }

        let input = AVAssetWriterInput(
            mediaType: .text, outputSettings: nil, sourceFormatHint: format
        )
        input.expectsMediaDataInRealTime = false
        input.marksOutputTrackAsEnabled = false   // a chapter track is not for display

        guard writer.canAdd(input) else {
            return .refused(reason: "\(writer.outputFileType.rawValue) "
                + "will not take a text track")
        }
        // The association is what makes a text track a CHAPTER track rather than
        // a subtitle track that happens to contain chapter names. Made before
        // the input is added, which is while the writer still accepts it.
        guard media.canAddTrackAssociation(
            withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue
        ) else {
            return .refused(reason: "the audio track would not take a chapter-list association")
        }
        media.addTrackAssociation(
            withTrackOf: input, type: AVAssetTrack.AssociationType.chapterList.rawValue
        )
        writer.add(input)
        return .attached(input)
    }

    /// Starts writing the chapter samples, and returns a task that completes
    /// when the last one is in.
    ///
    /// **Started, not awaited.** Two mistakes are available here and this
    /// signature exists to make both impossible.
    ///
    /// The first is polling `isReadyForMoreMediaData` in a loop, which looks
    /// simpler and deadlocks: a writer will not make an input ready while the
    /// calling thread is blocked waiting for it. One `requestMediaDataWhenReady`
    /// pump per input is the only arrangement that works, however few samples
    /// an input carries.
    ///
    /// The second is subtler and cost more to find: **awaiting this pump before
    /// the media pump has run also deadlocks.** A writer drives its inputs
    /// together, so the text input may not be asked for data until the audio
    /// input has been given some — and a caller that waits for the chapters to
    /// finish before starting the audio waits forever. So this returns
    /// immediately with a task, the caller pumps its media, and awaits the task
    /// before `finishWriting`.
    ///
    /// - Returns: a task yielding how many chapters were written, and the first
    ///   reason one was not.
    public static func beginWriting(
        _ chapters: [Chapter], to input: AVAssetWriterInput, timescale: CMTimeScale = 1_000
    ) -> Task<(written: Int, failure: String?), Never> {
        guard !chapters.isEmpty else {
            input.markAsFinished()
            return Task { (0, nil) }
        }

        let state = WriteState(chapters: chapters, timescale: timescale)
        let queue = DispatchQueue(label: "com.lathe.audio.chapters")
        // `AVAssetWriterInput` is not Sendable, and `requestMediaDataWhenReady`
        // exists precisely to be driven from another queue. The box states that
        // the crossing is deliberate rather than working around the checker by
        // accident.
        let boxed = InputBox(input)

        return Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let box = ContinuationBox(continuation)
                let writerInput = boxed.input
                writerInput.requestMediaDataWhenReady(on: queue) {
                    while writerInput.isReadyForMoreMediaData {
                        guard let chapter = state.next() else {
                            writerInput.markAsFinished()
                            box.resumeOnce()
                            return
                        }
                        guard let buffer = sampleBuffer(for: chapter, timescale: timescale) else {
                            state.recordFailure("could not build a sample for \"\(chapter.title)\"")
                            continue
                        }
                        if writerInput.append(buffer) {
                            state.recordWritten()
                        } else {
                            state.recordFailure("the writer refused the sample for \"\(chapter.title)\"")
                        }
                    }
                }
            }
            return (state.writtenCount, state.firstFailure)
        }
    }

    /// Carries the writer input across the concurrency boundary that
    /// `requestMediaDataWhenReady` is designed for.
    private final class InputBox: @unchecked Sendable {
        let input: AVAssetWriterInput
        init(_ input: AVAssetWriterInput) { self.input = input }
    }

    /// The cursor and tally the pump block mutates. A class because the block is
    /// re-entered on a queue and needs one shared position, not a copy.
    private final class WriteState: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [Chapter]
        private var written = 0
        private var failure: String?
        let timescale: CMTimeScale

        init(chapters: [Chapter], timescale: CMTimeScale) {
            self.remaining = chapters
            self.timescale = timescale
        }

        func next() -> Chapter? {
            lock.lock()
            defer { lock.unlock() }
            return remaining.isEmpty ? nil : remaining.removeFirst()
        }

        func recordWritten() {
            lock.lock()
            written += 1
            lock.unlock()
        }

        func recordFailure(_ reason: String) {
            lock.lock()
            if failure == nil { failure = reason }
            lock.unlock()
        }

        var firstFailure: String? {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }

        var writtenCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return written
        }
    }

    /// `requestMediaDataWhenReady` re-enters its block, so the continuation must
    /// be resumed exactly once — resuming twice is a crash, not an error.
    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resumeOnce() {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }

    // MARK: - Sample construction

    /// A `tx3g` format description built from a real sample description.
    ///
    /// `CMFormatDescriptionCreate` with the `tx3g` subtype and no extensions is
    /// the obvious thing to write, and it is accepted by `canAdd` — then the
    /// writer fails at `finishWriting` with "Media format - invalid parameter",
    /// long after the decision that caused it. A 3GPP text track needs an actual
    /// sample description: display flags, justification, a text box, a default
    /// style and a font table. The bridge below builds the description from
    /// those bytes, which is the only way to get one a writer will accept.
    public static func textFormatDescription() -> CMFormatDescription? {
        let description = sampleDescription()
        var format: CMFormatDescription?
        let status = description.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: kCFAllocatorDefault,
                bigEndianTextDescriptionData: base,
                size: description.count,
                flavor: nil,                 // NULL means QuickTime or ISO, which is what MP4 is
                mediaType: kCMMediaType_Text,
                formatDescriptionOut: &format
            )
        }
        return status == noErr ? format : nil
    }

    /// The `tx3g` sample description, big-endian, as the format defines it.
    ///
    /// Every field is written even where zero, because the structure is fixed
    /// width and a short one is not a smaller description — it is a malformed
    /// one. The font table at the end is not optional either: a `tx3g` entry
    /// without an `ftab` box is rejected.
    public static func sampleDescription() -> Data {
        var out = Data()
        func u8(_ value: UInt8) { out.append(value) }
        func u16(_ value: UInt16) {
            out.append(UInt8(value >> 8)); out.append(UInt8(value & 0xFF))
        }
        func u32(_ value: UInt32) {
            out.append(UInt8((value >> 24) & 0xFF)); out.append(UInt8((value >> 16) & 0xFF))
            out.append(UInt8((value >> 8) & 0xFF)); out.append(UInt8(value & 0xFF))
        }
        func fourCC(_ text: String) { out.append(contentsOf: Array(text.utf8)) }

        let fontName = "Serif"
        let fontTableSize = UInt32(4 + 4 + 2 + 2 + 1 + fontName.utf8.count)
        let totalSize = UInt32(38 + 8 + 12 + 6) + fontTableSize

        u32(totalSize)
        fourCC("tx3g")
        for _ in 0..<6 { u8(0) }              // reserved
        u16(1)                                // data reference index

        u32(0)                                // display flags
        u8(0)                                 // horizontal justification: left
        u8(0)                                 // vertical justification: top
        for _ in 0..<4 { u8(0) }              // background colour, transparent

        // BoxRecord: a zero box means "the whole track".
        u16(0); u16(0); u16(0); u16(0)

        // StyleRecord: no styled range, font 1, 12pt, opaque white.
        u16(0); u16(0)                        // start and end character
        u16(1)                                // font ID
        u8(0)                                 // face style flags
        u8(12)                                // font size
        u8(255); u8(255); u8(255); u8(255)    // text colour

        // FontTableBox — required, not decorative.
        u32(fontTableSize)
        fourCC("ftab")
        u16(1)                                // one entry
        u16(1)                                // font ID, matching the style above
        u8(UInt8(fontName.utf8.count))
        fourCC(fontName)

        return out
    }

    /// One chapter title as a 3GPP text sample.
    ///
    /// The payload is a 16-bit big-endian byte count followed by UTF-8. The
    /// count is of BYTES, not characters, which is the detail that turns a
    /// chapter called "Café" into a truncated one on any file where the two
    /// differ.
    public static func samplePayload(for title: String) -> Data {
        let utf8 = Array(title.utf8)
        let clipped = utf8.count > Int(UInt16.max) ? Array(utf8.prefix(Int(UInt16.max))) : utf8
        var data = Data()
        data.append(UInt8((clipped.count >> 8) & 0xFF))
        data.append(UInt8(clipped.count & 0xFF))
        data.append(contentsOf: clipped)
        return data
    }

    private static func sampleBuffer(for chapter: Chapter, timescale: CMTimeScale) -> CMSampleBuffer? {
        guard let format = textFormatDescription() else { return nil }
        let payload = samplePayload(for: chapter.title)

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
            duration: CMTime(seconds: chapter.durationSeconds, preferredTimescale: timescale),
            presentationTimeStamp: CMTime(seconds: chapter.startSeconds, preferredTimescale: timescale),
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
}
#endif
