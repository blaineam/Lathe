#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Foundation
import LatheCore

/// The sample-copying remux that ``SubtitleMuxer`` and ``ChapterWriter`` are
/// both built on: every track of a file copied into a new container, bit for
/// bit, with the file's tags, a chapter list, and whatever extra inputs the
/// caller adds.
///
/// ## Why one of these and not one per feature
///
/// Adding subtitles and replacing chapters are the same operation with a
/// different track added at the end. Both have to carry the video, the audio,
/// the existing subtitles with their alternate group, the tags, and a chapter
/// list with the `chap` association that makes it one — and both have to drive
/// several writer inputs at once without deadlocking. Written twice, the two
/// copies drift: one learns that a kept subtitle track needs its group rebuilt
/// and the other quietly produces a menu that lists nothing.
///
/// So the caller decides only what is particular to it: which of the source's
/// subtitle tracks to keep, which chapters to write, what else to add, and how
/// to name a failure. Everything else happens here, in this order:
///
/// 1. ``init(asset:duration:writingTo:fileType:metadata:stage:progress:)``
///    opens the writer with the file-level tags.
/// 2. ``copyTracks(keepingSubtitle:)`` adds one passthrough input per source
///    track, in track order.
/// 3. ``attachChapters(_:)`` adds the chapter track, hung off the picture when
///    there is one and off the sound when there is not.
/// 4. The caller adds its own inputs with ``add(_:pump:)``.
/// 5. ``groupTracks(legibleDefault:)`` writes the alternate groups.
/// 6. ``run()`` drives it all and finishes the file.
///
/// ## What is not carried
///
/// Text tracks other than the chapter list: a `.text` track is either the
/// chapter list, which is rebuilt, or something no player shows. Anything the
/// destination refuses is named in ``dropped`` rather than lost quietly.
///
/// Not `Sendable`, and not meant to be: one of these lives inside one call. The
/// pumps it builds capture only the reader, the input and the writer, which is
/// the crossing `requestMediaDataWhenReady` exists for.
final class TrackRemux {

    /// A failure, with the step it happened in. Callers translate it into their
    /// own error type; the stage reads as the end of "failed while …".
    struct Failure: Error, Equatable {
        let stage: String
        let reason: String
    }

    let asset: AVURLAsset
    let writer: AVAssetWriter
    let fileType: AVFileType
    let duration: CMTime

    /// Source tracks that are not in the output, each with the reason.
    private(set) var dropped: [String] = []

    /// Whether any of those was picture or sound — which, unlike a subtitle,
    /// is a loss a caller may not want to accept.
    private(set) var droppedMedia = false

    /// Source subtitle tracks copied across, and ones the caller chose to leave.
    private(set) var keptSubtitleCount = 0
    private(set) var removedSubtitleCount = 0

    private(set) var videoInputs: [AVAssetWriterInput] = []
    private var audioInputs: [(input: AVAssetWriterInput, enabled: Bool)] = []
    private var legibleInputs: [(input: AVAssetWriterInput, enabled: Bool)] = []

    private var pumps: [MetaWriterPump] = []
    private var readers: [AVAssetReader] = []
    private var chapterInput: AVAssetWriterInput?
    private var chapters: [Chapter] = []

    private let stage: String
    private let progress: ProgressHandle
    private let clock = MetaMuxClock()

    init(
        asset: AVURLAsset,
        duration: CMTime,
        writingTo url: URL,
        fileType: AVFileType,
        metadata: [AVMetadataItem],
        stage: String,
        progress: ProgressHandle
    ) throws {
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        } catch {
            throw Failure(stage: "opening the output", reason: (error as NSError).localizedDescription)
        }
        writer.metadata = metadata
        self.asset = asset
        self.duration = duration
        self.fileType = fileType
        self.stage = stage
        self.progress = progress
    }

    /// The input a chapter list hangs off: the first picture, else the first
    /// sound. A player looks for the chapters on the track it is presenting,
    /// and an audiobook has only one.
    var chapterAnchor: AVAssetWriterInput? {
        videoInputs.first ?? audioInputs.first?.input
    }

    // MARK: - Copying

    /// One passthrough input per source track, in track order.
    ///
    /// - Parameter keepingSubtitle: asked of each subtitle track in the source;
    ///   `false` leaves it out and counts it in ``removedSubtitleCount``.
    func copyTracks(keepingSubtitle: (AVAssetTrack) async -> Bool = { _ in true }) async throws {
        let sourceTracks: [AVAssetTrack]
        do {
            sourceTracks = try await asset.load(.tracks).sorted { $0.trackID < $1.trackID }
        } catch {
            throw Failure(stage: "reading the tracks", reason: (error as NSError).localizedDescription)
        }
        // Progress follows the picture, or the sound when there is no picture:
        // the track whose end is the file's end.
        let progressTrackID = (sourceTracks.first { $0.mediaType == .video }
            ?? sourceTracks.first { $0.mediaType == .audio })?.trackID

        let writer = writer
        let progress = progress
        let clock = clock
        let stage = stage
        let totalSeconds = duration.seconds

        for track in sourceTracks {
            let type = track.mediaType
            let kind = Self.kindName(type)
            // Chapter text tracks are rebuilt, with their association.
            if type == .text { continue }

            if type == .subtitle, await !keepingSubtitle(track) {
                removedSubtitleCount += 1
                continue
            }

            let format = (try? await track.load(.formatDescriptions))?.first
            let codec = format.map { SubtitleMuxer.fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown"
            let isMedia = type == .video || type == .audio

            // The reader is checked before the input is added: an input cannot
            // be taken back out of a writer, and one that never receives a
            // sample stalls the whole file.
            guard let reader = try? AVAssetReader(asset: asset) else {
                dropped.append("\(kind) track \(track.trackID) (\(codec)): could not be opened for reading")
                droppedMedia = droppedMedia || isMedia
                continue
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                dropped.append("\(kind) track \(track.trackID) (\(codec)): cannot be read in passthrough")
                droppedMedia = droppedMedia || isMedia
                continue
            }
            reader.add(output)

            let input = AVAssetWriterInput(mediaType: type, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            if type == .video {
                input.transform = (try? await track.load(.preferredTransform)) ?? .identity
                if let scale = try? await track.load(.naturalTimeScale), scale > 0 {
                    input.mediaTimeScale = scale
                }
            }
            if let code = (try? await track.load(.languageCode)) ?? nil { input.languageCode = code }
            if let tag = (try? await track.load(.extendedLanguageTag)) ?? nil { input.extendedLanguageTag = tag }
            input.metadata = (try? await track.load(.metadata)) ?? []
            let enabled = (try? await track.load(.isEnabled)) ?? true
            input.marksOutputTrackAsEnabled = enabled

            guard writer.canAdd(input) else {
                dropped.append("\(kind) track \(track.trackID) (\(codec)): \(fileType.rawValue) will not hold it")
                droppedMedia = droppedMedia || isMedia
                continue
            }
            writer.add(input)
            readers.append(reader)

            switch type {
            case .video: videoInputs.append(input)
            case .audio: audioInputs.append((input, enabled))
            case .subtitle:
                legibleInputs.append((input, enabled))
                keptSubtitleCount += 1
            default: break
            }

            let isProgressTrack = track.trackID == progressTrackID
            let label = "\(kind) \(track.trackID)"
            pumps.append(MetaWriterPump(input: input, label: label) {
                guard let sample = output.copyNextSampleBuffer() else {
                    if reader.status == .failed {
                        throw Failure(
                            stage: "reading \(label)",
                            reason: reader.error.map { ($0 as NSError).localizedDescription } ?? "the reader failed"
                        )
                    }
                    return false
                }
                guard input.append(sample) else {
                    throw Failure(
                        stage: "copying \(label)",
                        reason: writer.error.map { ($0 as NSError).localizedDescription }
                            ?? "the writer rejected a sample"
                    )
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let length = CMSampleBufferGetDuration(sample)
                if pts.isValid {
                    clock.observe(end: length.isValid ? CMTimeAdd(pts, length) : pts)
                }
                if isProgressTrack {
                    let seconds = max(0, clock.endSeconds)
                    try progress.checkpoint(LatheProgress(
                        fraction: totalSeconds > 0 ? min(1, seconds / totalSeconds) : nil,
                        stage: stage,
                        unitIndex: UInt64(seconds),
                        unitCount: UInt64(max(0, totalSeconds))
                    ))
                } else {
                    try progress.checkCancellation()
                }
                return true
            })
        }
    }

    // MARK: - Chapters

    /// Adds a chapter track holding `list`, normalised against the file's
    /// length. An empty list adds nothing, which is how chapters are removed.
    ///
    /// - Returns: the attachment, so a caller can decide whether a refusal is
    ///   a failure (a chapter write) or a note (a subtitle write).
    @discardableResult
    func attachChapters(_ list: [Chapter]) -> ChapterTrack.Attachment {
        let normalised = list.normalisedChapters(totalDuration: duration.isNumeric ? duration.seconds : nil)
        guard let anchor = chapterAnchor else {
            return .refused(reason: "there is no video or audio track to hang chapters on")
        }
        let attachment = ChapterTrack.makeInput(for: normalised, writer: writer, associatedWith: anchor)
        if let input = attachment.input {
            chapterInput = input
            chapters = normalised
        }
        return attachment
    }

    /// The chapters that will be written, after normalisation.
    var chaptersToWrite: [Chapter] { chapterInput == nil ? [] : chapters }

    // MARK: - Extra inputs

    /// Adds a caller-built input and the pump that feeds it. `legible` inputs
    /// join the subtitle alternate group; `enabled` is whether it asks to be
    /// that group's default.
    func add(_ input: AVAssetWriterInput, legible: Bool = false, enabled: Bool = false, pump: MetaWriterPump) {
        writer.add(input)
        if legible { legibleInputs.append((input, enabled)) }
        pumps.append(pump)
    }

    // MARK: - Groups

    /// Writes the alternate groups: one for every subtitle track, kept and new
    /// together, and one for the audio when there is more than one track.
    ///
    /// The subtitle group's default is `legibleDefault`, else whichever track
    /// the source had switched on, else none — subtitles start off. A default
    /// demotes every other track in the group; two enabled tracks in a group is
    /// a file players disagree about.
    func groupTracks(legibleDefault preferred: AVAssetWriterInput? = nil) {
        let legibleDefault = preferred ?? legibleInputs.first(where: { $0.enabled })?.input
        if !legibleInputs.isEmpty {
            for (input, _) in legibleInputs where input !== legibleDefault {
                input.marksOutputTrackAsEnabled = false
            }
            let group = AVAssetWriterInputGroup(inputs: legibleInputs.map(\.input), defaultInput: legibleDefault)
            if writer.canAdd(group) {
                writer.add(group)
            } else {
                dropped.append("subtitle grouping: the writer refused the alternate group, "
                    + "so players may list the tracks separately")
            }
        }
        if audioInputs.count > 1 {
            let group = AVAssetWriterInputGroup(
                inputs: audioInputs.map(\.input),
                defaultInput: audioInputs.first(where: { $0.enabled })?.input ?? audioInputs[0].input
            )
            if writer.canAdd(group) { writer.add(group) }
        }
    }

    // MARK: - Running

    /// Writes the file.
    ///
    /// - Returns: how many chapters went in, and the first reason one did not.
    /// - Throws: ``LatheCore/LatheError/cancelled(atUnit:)`` on cancellation,
    ///   whatever a caller's pump threw, and ``Failure`` for the rest. The
    ///   output file is left for the caller to remove. A short chapter count is
    ///   returned, not thrown: whether it is a failure is the caller's call.
    func run() async throws -> (chaptersWritten: Int, chapterFailure: String?) {
        guard writer.startWriting() else {
            throw Failure(
                stage: "starting",
                reason: writer.error.map { ($0 as NSError).localizedDescription } ?? "startWriting returned false"
            )
        }
        writer.startSession(atSourceTime: .zero)
        for reader in readers {
            guard reader.startReading() else {
                writer.cancelWriting()
                throw Failure(
                    stage: "starting to read",
                    reason: reader.error.map { ($0 as NSError).localizedDescription } ?? "a reader would not start"
                )
            }
        }

        // Started, not awaited, before the media pumps run — see
        // ``ChapterTrack/beginWriting(_:to:timescale:)`` for the deadlock the
        // other order causes.
        let chapterWrite = chapterInput.map { ChapterTrack.beginWriting(chapters, to: $0) }

        let running = pumps
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for pump in running {
                    group.addTask { try await pump.run() }
                }
                try await group.waitForAll()
            }
        } catch {
            for reader in readers { reader.cancelReading() }
            writer.cancelWriting()
            _ = await chapterWrite?.value
            if error is CancellationError { throw LatheError.cancelled(atUnit: nil) }
            if error is LatheError || error is Failure || error is SubtitleError || error is ChapterError {
                throw error
            }
            throw Failure(stage: "copying", reason: (error as NSError).localizedDescription)
        }
        let outcome = await chapterWrite?.value

        writer.endSession(atSourceTime: max(clock.end ?? duration, duration))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure(
                stage: "finishing",
                reason: writer.error.map { ($0 as NSError).localizedDescription }
                    ?? "the writer ended in state \(writer.status.rawValue)"
            )
        }
        return (outcome?.written ?? 0, outcome?.failure)
    }

    // MARK: - Files

    /// A hidden sibling of `destination` to write into, so a failed or
    /// cancelled write never leaves a partial file under the real name.
    static func scratchURL(beside destination: URL, prefix: String) -> URL {
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return destination.deletingLastPathComponent()
            .appendingPathComponent("\(prefix)\(UUID().uuidString).\(destination.pathExtension)")
    }

    /// Moves a finished scratch file over `destination`.
    static func moveIntoPlace(_ scratch: URL, at destination: URL) throws {
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: scratch)
            } else {
                try FileManager.default.moveItem(at: scratch, to: destination)
            }
        } catch {
            throw LatheError.writeFailed(
                path: destination.lastPathComponent, reason: (error as NSError).localizedDescription
            )
        }
    }

    static func kindName(_ type: AVMediaType) -> String {
        switch type {
        case .video: "video"
        case .audio: "audio"
        case .subtitle: "subtitle"
        case .closedCaption: "closed-caption"
        case .timecode: "timecode"
        case .metadata: "timed-metadata"
        default: type.rawValue
        }
    }
}
#endif
