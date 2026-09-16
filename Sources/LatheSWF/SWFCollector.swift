import Foundation
import LatheCore

/// Accumulates what a single pass over a tag stream finds.
///
/// A class rather than a struct because the walk hands it one tag at a time
/// through a closure and it is genuinely a pile of mutable state; a value type
/// here would be a value type pretending. It is created, used and discarded
/// inside one synchronous call and is deliberately not `Sendable`: nothing about
/// a half-finished extraction should be shared across tasks.
///
/// ## Why two tags cannot be handled where they are found
///
/// Most tags are self-contained and are written the moment they are seen. Two
/// are not, and both are deferred to ``finish()``:
///
/// - **`DefineBits` needs `JPEGTables`**, which is a *different tag* and is only
///   conventionally earlier in the file. Nothing in the format requires it to
///   come first, so a reader that merged on arrival would silently produce
///   nothing for any file that put its tables at the end.
/// - **A streaming soundtrack has no single tag at all.** It is a
///   `SoundStreamHead` followed by however many `SoundStreamBlock` tags the
///   timeline runs for, interleaved with `ShowFrame`. The file is only complete
///   when the timeline ends — and there is one such soundtrack *per timeline*,
///   so a movie with sprites has several, which must not be concatenated into
///   one.
final class SWFCollector {

    private let header: SWFHeader
    private let name: String
    private let limits: SWFLimits
    private let destination: URL?
    /// Whether ``destination`` has been created yet. The directory is made on
    /// the first write rather than up front, so a file that turns out to be
    /// LZMA — or malformed — does not leave an empty folder behind.
    private var didCreateDestination = false

    private var assets: [SWFAsset] = []
    private var census: [UInt16: (count: Int, byteCount: Int)] = [:]
    private var usedFileNames: Set<String> = []

    /// A grouped omission: the same reason for the same thing, counted.
    private struct OmissionKey: Hashable {
        let what: String
        let reason: SWFOmission.Reason
    }
    private var omissions: [OmissionKey: (count: Int, byteCount: Int, detail: String?)] = [:]
    private var omissionOrder: [OmissionKey] = []

    /// The one shared JPEG table block, if the file has one.
    private var jpegTables: Data?
    /// `DefineBits` payloads, held until the tables are known.
    private var tablelessJPEGs: [(characterID: UInt16, data: Data, byteCount: Int)] = []

    /// Per-timeline streaming soundtracks, keyed by sprite path.
    private var streamDescriptions: [String: SWFSoundDecoder.Description] = [:]
    private var streamPayloads: [String: Data] = [:]
    private var streamSpritePaths: [String: [UInt16]] = [:]
    private var streamOrder: [String] = []

    init(header: SWFHeader, name: String, limits: SWFLimits, destination: URL?) {
        self.header = header
        self.name = name
        self.limits = limits
        self.destination = destination
    }

    // MARK: - One tag

    /// Takes one tag.
    ///
    /// Only genuinely fatal problems propagate. Everything a single tag can get
    /// wrong about *itself* — a bitmap that does not inflate, a sound whose
    /// flags run off the end of its body — is caught here, recorded as a
    /// malformed omission, and the walk continues. A corrupt movie with eleven
    /// good bitmaps and one bad one should yield eleven bitmaps.
    func accept(_ record: SWFTagRecord) throws {
        let code = record.code.rawValue
        let existing = census[code] ?? (0, 0)
        census[code] = (existing.count + 1, existing.byteCount + record.length)

        do {
            switch record.code {
            case .jpegTables:
                // At most one per file. A second is ignored rather than allowed
                // to replace the first, because the first is the one every
                // earlier DefineBits was authored against.
                var body = record.body
                let data = try body.rest()
                if jpegTables == nil, !data.isEmpty { jpegTables = Data(data) }

            case .defineBits:
                var body = record.body
                let characterID = try body.u16()
                let data = try body.rest()
                tablelessJPEGs.append((characterID, Data(data), record.length))

            case .defineBitsJPEG2, .defineBitsJPEG3, .defineBitsJPEG4:
                try acceptJPEG(record)

            case .defineBitsLossless, .defineBitsLossless2:
                try acceptLossless(record)

            case .defineSound:
                try acceptDefineSound(record)

            case .soundStreamHead, .soundStreamHead2:
                let description = try SWFSoundDecoder.parseStreamHead(record.body)
                let key = timelineKey(record.spritePath)
                streamDescriptions[key] = description
                streamSpritePaths[key] = record.spritePath
                if !streamOrder.contains(key) { streamOrder.append(key) }

            case .soundStreamBlock:
                let key = timelineKey(record.spritePath)
                // Without a head the codec is unknown, and guessing it from the
                // bytes would be guessing what to strip from the front of every
                // block. Recorded rather than salvaged.
                guard let description = streamDescriptions[key] else {
                    note(
                        "SoundStreamBlock outside any SoundStreamHead", reason: .malformed,
                        byteCount: record.length,
                        detail: "the timeline's soundtrack has no header declaring its codec"
                    )
                    return
                }
                let payload = try SWFSoundDecoder.streamBlockPayload(
                    record.body, format: description.format
                )
                streamPayloads[key, default: Data()].append(payload)
                streamSpritePaths[key] = record.spritePath
                if !streamOrder.contains(key) { streamOrder.append(key) }

            case .defineVideoStream:
                try acceptVideoStream(record)

            case .videoFrame:
                note(
                    "VideoFrame", reason: .codecNotDecodable, byteCount: record.length,
                    detail: "frames of an embedded Flash video stream"
                )

            case .defineBinaryData:
                try acceptBinaryData(record)

            default:
                break  // The census already accounts for it.
            }
        } catch let error as LatheError {
            // Only a problem with the tag's *contents* is survivable. A failure
            // to write, a cancellation or a memory refusal is about the
            // extraction rather than about this tag, and recording one of those
            // as "malformed tag" would turn a full disk into a report claiming
            // the movie was corrupt.
            switch error {
            case .invalidInput, .encodingFailed, .decodeUnavailable:
                let detail = "\(name): skipping malformed \(record.code.description)"
                LatheLog.swf.debug("\(detail, privacy: .public)")
                note(
                    record.code.description, reason: .malformed, byteCount: record.length,
                    detail: error.errorDescription
                )
            default:
                throw error
            }
        }
    }

    // MARK: - Images

    private func acceptJPEG(_ record: SWFTagRecord) throws {
        var body = record.body
        let characterID = try body.u16()

        var alphaData = Data()
        var imageData: Data

        if record.code == .defineBitsJPEG2 {
            imageData = Data(try body.rest())
        } else {
            // JPEG3 and JPEG4 both declare the image data's length up front and
            // put the alpha channel after it. JPEG4 inserts a UI16 deblocking
            // parameter between the two, which is the only difference and the
            // easy thing to get wrong — reading it in the JPEG3 case takes two
            // bytes off the front of the image.
            let imageLength = Int(try body.u32())
            if record.code == .defineBitsJPEG4 { _ = try body.u16() }
            guard imageLength <= body.remaining else {
                throw LatheError.invalidInput(
                    reason: "\(name): character \(characterID) claims \(imageLength) bytes of "
                        + "image data with only \(body.remaining) left in the tag"
                )
            }
            imageData = Data(try body.bytes(imageLength))
            alphaData = Data(try body.rest())
        }

        guard !imageData.isEmpty else {
            note(
                record.code.description, reason: .malformed, byteCount: record.length,
                detail: "character \(characterID) carries no image data"
            )
            return
        }

        imageData = SWFImageDecoder.strippingErroneousJPEGPrefix(imageData)
        let payload = SWFImageDecoder.sniff(imageData)

        // A JPEG with a real alpha channel becomes a PNG, because JPEG has no
        // way to carry the transparency and dropping it would produce an image
        // that looks entirely correct and is entirely wrong.
        if payload == .jpeg, !alphaData.isEmpty,
           let composed = SWFImageDecoder.composingAlpha(
            jpeg: imageData, alphaZlib: alphaData, limits: limits, name: name
           ) {
            let size = SWFImageDecoder.pixelSize(of: composed)
            try emitImage(
                composed, characterID: characterID, record: record, extension: "png",
                width: size?.width, height: size?.height, source: .jpegWithAlpha, hasAlpha: true
            )
            return
        }

        if payload == .jpeg, !alphaData.isEmpty {
            note(
                "\(record.code) alpha channel", reason: .malformed, byteCount: alphaData.count,
                detail: "character \(characterID)'s alpha channel could not be applied; the "
                    + "JPEG was written without it"
            )
        }

        let source: SWFImageSource
        switch payload {
        case .jpeg: source = .jpeg
        case .png: source = .png
        case .gif: source = .gif
        default:
            note(
                record.code.description, reason: .malformed, byteCount: record.length,
                detail: "character \(characterID) holds neither JPEG, PNG nor GIF data"
            )
            return
        }

        let size = SWFImageDecoder.pixelSize(of: imageData)
        try emitImage(
            imageData, characterID: characterID, record: record,
            extension: payload.filenameExtension, width: size?.width, height: size?.height,
            source: source, hasAlpha: payload == .png || payload == .gif
        )
    }

    private func acceptLossless(_ record: SWFTagRecord) throws {
        let decoded = try SWFImageDecoder.decodeLossless(
            tag: record.code, body: record.body, limits: limits, name: name
        )
        guard let png = SWFImageDecoder.pngData(decoded.raster) else {
            throw LatheError.encodingFailed(
                stage: "PNG", code: nil,
                reason: "character \(decoded.characterID)'s \(decoded.raster.width)×"
                    + "\(decoded.raster.height) raster could not be encoded"
            )
        }
        try emitImage(
            png, characterID: decoded.characterID, record: record, extension: "png",
            width: decoded.raster.width, height: decoded.raster.height,
            source: decoded.format.imageSource, hasAlpha: decoded.format.hasAlpha
        )
    }

    private func emitImage(
        _ data: Data, characterID: UInt16, record: SWFTagRecord, extension fileExtension: String,
        width: Int?, height: Int?, source: SWFImageSource, hasAlpha: Bool
    ) throws {
        let fileName = try emit(
            data, base: String(format: "character-%05d", Int(characterID)),
            extension: fileExtension
        )
        assets.append(
            SWFAsset(
                fileName: fileName, characterID: characterID,
                sourceTag: record.code.description, sourceTagCode: record.code.rawValue,
                byteCount: data.count,
                content: .image(
                    width: width, height: height, source: source, hasAlpha: hasAlpha
                ),
                spritePath: record.spritePath
            )
        )
    }

    // MARK: - Sound

    private func acceptDefineSound(_ record: SWFTagRecord) throws {
        let sound = try SWFSoundDecoder.parseDefineSound(record.body)
        let description = sound.description

        let file: (data: Data, fileExtension: String)
        switch description.format {
        case .mp3:
            let frames = SWFSoundDecoder.mp3Payload(sound.data)
            guard !frames.isEmpty else {
                note(
                    "DefineSound", reason: .malformed, byteCount: record.length,
                    detail: "character \(sound.characterID) declares MP3 and carries no frames"
                )
                return
            }
            file = (frames, "mp3")

        case .uncompressedNativeEndian, .uncompressedLittleEndian:
            guard !sound.data.isEmpty else {
                note(
                    "DefineSound", reason: .malformed, byteCount: record.length,
                    detail: "character \(sound.characterID) declares PCM and carries no samples"
                )
                return
            }
            file = (
                SWFSoundDecoder.wavData(
                    pcm: Data(sound.data), sampleRateHz: description.sampleRateHz,
                    bitsPerSample: description.bitsPerSample,
                    channelCount: description.channelCount
                ), "wav"
            )

        default:
            note(
                "DefineSound (\(description.format))", reason: .codecNotDecodable,
                byteCount: record.length,
                detail: "\(description.format) has no decoder on Apple platforms and Lathe adds "
                    + "no third-party one; character \(sound.characterID) was left in place"
            )
            return
        }

        let fileName = try emit(
            file.data, base: String(format: "character-%05d", Int(sound.characterID)),
            extension: file.fileExtension
        )
        assets.append(
            SWFAsset(
                fileName: fileName, characterID: sound.characterID,
                sourceTag: record.code.description, sourceTagCode: record.code.rawValue,
                byteCount: file.data.count,
                content: .sound(
                    SWFSoundInfo(
                        format: description.format, sampleRateHz: description.sampleRateHz,
                        bitsPerSample: description.bitsPerSample,
                        channelCount: description.channelCount,
                        declaredSampleCount: sound.sampleCount, isStreamingSoundtrack: false
                    )
                ),
                spritePath: record.spritePath
            )
        )
    }

    /// A key naming the timeline a streaming soundtrack belongs to.
    ///
    /// The main timeline and every sprite each have their own, and they are
    /// genuinely separate sounds: concatenating a sprite's loop onto the main
    /// soundtrack would produce one file of two unrelated pieces of music.
    private func timelineKey(_ spritePath: [UInt16]) -> String {
        spritePath.isEmpty ? "main" : "sprite-" + spritePath.map(String.init).joined(separator: "-")
    }

    private func flushStreamingSoundtracks() throws {
        for key in streamOrder {
            guard let description = streamDescriptions[key] else { continue }
            let payload = streamPayloads[key] ?? Data()
            let spritePath = streamSpritePaths[key] ?? []

            guard !payload.isEmpty else { continue }

            let file: (data: Data, fileExtension: String)
            switch description.format {
            case .mp3:
                file = (payload, "mp3")
            case .uncompressedNativeEndian, .uncompressedLittleEndian:
                file = (
                    SWFSoundDecoder.wavData(
                        pcm: payload, sampleRateHz: description.sampleRateHz,
                        bitsPerSample: description.bitsPerSample,
                        channelCount: description.channelCount
                    ), "wav"
                )
            default:
                note(
                    "streaming soundtrack (\(description.format))", reason: .codecNotDecodable,
                    byteCount: payload.count,
                    detail: "the \(key) timeline's soundtrack is \(description.format), which "
                        + "has no decoder on Apple platforms"
                )
                continue
            }

            let fileName = try emit(
                file.data, base: "soundtrack-\(key)", extension: file.fileExtension
            )
            assets.append(
                SWFAsset(
                    fileName: fileName, characterID: nil, sourceTag: "SoundStreamBlock",
                    sourceTagCode: SWFTagCode.soundStreamBlock.rawValue,
                    byteCount: file.data.count,
                    content: .sound(
                        SWFSoundInfo(
                            format: description.format, sampleRateHz: description.sampleRateHz,
                            bitsPerSample: description.bitsPerSample,
                            channelCount: description.channelCount, declaredSampleCount: nil,
                            isStreamingSoundtrack: true
                        )
                    ),
                    spritePath: spritePath
                )
            )
        }
    }

    // MARK: - Video

    /// Records an embedded video stream, which is always an omission.
    ///
    /// Every codec SWF can carry — Sorenson H.263, Screen video, VP6 — is one no
    /// Apple framework decodes, and none is a codec anything still produces.
    /// Recording the stream's dimensions, frame count and codec is the useful
    /// thing available: it tells a caller exactly what they would need a
    /// different tool for, rather than leaving a silent gap where a cartoon was.
    private func acceptVideoStream(_ record: SWFTagRecord) throws {
        var body = record.body
        let characterID = try body.u16()
        let frameCount = try body.u16()
        let width = try body.u16()
        let height = try body.u16()
        _ = try body.u8()  // reserved, deblocking and smoothing flags
        let codecID = try body.u8()

        let codec: String
        switch codecID {
        case 2: codec = "Sorenson H.263"
        case 3: codec = "Screen video"
        case 4: codec = "VP6"
        case 5: codec = "VP6 with alpha"
        case 6: codec = "Screen video v2"
        default: codec = "codec \(codecID)"
        }

        note(
            "DefineVideoStream (\(codec))", reason: .codecNotDecodable, byteCount: record.length,
            detail: "character \(characterID): \(width)×\(height), \(frameCount) frames. No "
                + "Apple framework decodes \(codec), and Lathe adds no third-party decoder."
        )
    }

    // MARK: - Embedded files

    /// `DefineBinaryData` is whatever an ActionScript 3 author put in an
    /// `[Embed]` — very often a whole PNG, MP3 or XML file.
    ///
    /// The tag says nothing about the type, so the type comes from the bytes.
    /// Anything unrecognised is still written, as `.bin`: it is a file somebody
    /// deliberately embedded, and a caller can identify it far better than a
    /// magic-number table can.
    private func acceptBinaryData(_ record: SWFTagRecord) throws {
        var body = record.body
        let characterID = try body.u16()
        _ = try body.u32()  // reserved, must be zero
        let data = Data(try body.rest())
        guard !data.isEmpty else { return }

        let payload = SWFImageDecoder.sniff(data)
        let fileName = try emit(
            data, base: String(format: "binary-%05d", Int(characterID)),
            extension: payload.filenameExtension
        )
        assets.append(
            SWFAsset(
                fileName: fileName, characterID: characterID,
                sourceTag: record.code.description, sourceTagCode: record.code.rawValue,
                byteCount: data.count, content: .binaryData(sniffedAs: payload.rawValue),
                spritePath: record.spritePath
            )
        )
    }

    // MARK: - Output

    /// Writes one file, or — when inspecting — decides what it would have been
    /// called and writes nothing.
    ///
    /// The unique name is computed either way, so that an inspection and an
    /// extraction of the same file resolve collisions identically and their
    /// reports differ in exactly one field.
    private func emit(_ data: Data, base: String, extension fileExtension: String) throws
        -> String?
    {
        var candidate = "\(base).\(fileExtension)"
        var suffix = 2
        while usedFileNames.contains(candidate) {
            candidate = "\(base)-\(suffix).\(fileExtension)"
            suffix += 1
        }
        usedFileNames.insert(candidate)

        guard let destination else { return nil }
        try ensureDestinationExists(destination)
        let url = destination.appendingPathComponent(candidate)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw LatheError.writeFailed(
                path: candidate, reason: (error as NSError).localizedDescription
            )
        }
        return candidate
    }

    private func ensureDestinationExists(_ directory: URL) throws {
        guard !didCreateDestination else { return }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            didCreateDestination = true
        } catch {
            throw LatheError.writeFailed(
                path: directory.lastPathComponent, reason: (error as NSError).localizedDescription
            )
        }
    }

    private func note(
        _ what: String, reason: SWFOmission.Reason, byteCount: Int, detail: String?
    ) {
        let key = OmissionKey(what: what, reason: reason)
        if let existing = omissions[key] {
            omissions[key] = (
                existing.count + 1, existing.byteCount + byteCount, existing.detail ?? detail
            )
        } else {
            omissions[key] = (1, byteCount, detail)
            omissionOrder.append(key)
        }
    }

    // MARK: - Finishing

    func finish() throws -> SWFCaptureReport {
        try flushTablelessJPEGs()
        try flushStreamingSoundtracks()

        return SWFCaptureReport(
            source: name,
            header: header,
            assets: assets,
            omissions: assembledOmissions(),
            tagCensus: assembledCensus(),
            verdict: verdict()
        )
    }

    /// Reunites every `DefineBits` payload with the file's one `JPEGTables`
    /// block.
    private func flushTablelessJPEGs() throws {
        guard !tablelessJPEGs.isEmpty else { return }

        for entry in tablelessJPEGs {
            var jpeg: Data
            let source: SWFImageSource

            if let tables = jpegTables {
                jpeg = SWFImageDecoder.mergingJPEGTables(tables, into: entry.data)
                source = .jpegSharingTables
            } else {
                // No tables anywhere in the file. A few authoring tools wrote a
                // self-contained JPEG into DefineBits anyway, so the payload is
                // offered to the decoder before it is written off — if it
                // decodes, it is a real JPEG and worth keeping.
                jpeg = SWFImageDecoder.strippingErroneousJPEGPrefix(entry.data)
                guard SWFImageDecoder.pixelSize(of: jpeg) != nil else {
                    note(
                        "DefineBits without JPEGTables", reason: .malformed,
                        byteCount: entry.byteCount,
                        detail: "character \(entry.characterID) holds JPEG scan data whose "
                            + "Huffman and quantisation tables belong in a JPEGTables tag that "
                            + "this file does not contain; it cannot be decoded"
                    )
                    continue
                }
                source = .jpeg
            }

            let size = SWFImageDecoder.pixelSize(of: jpeg)
            let fileName = try emit(
                jpeg, base: String(format: "character-%05d", Int(entry.characterID)),
                extension: "jpg"
            )
            assets.append(
                SWFAsset(
                    fileName: fileName, characterID: entry.characterID, sourceTag: "DefineBits",
                    sourceTagCode: SWFTagCode.defineBits.rawValue, byteCount: jpeg.count,
                    content: .image(
                        width: size?.width, height: size?.height, source: source, hasAlpha: false
                    ),
                    spritePath: []
                )
            )
        }
    }

    /// The explicitly recorded omissions, plus one line per kind of content that
    /// was never a candidate: vector art, and script.
    ///
    /// The second half is what makes the report answer "why did I get nothing
    /// out of this file". Without it, a cartoon and an empty file produce the
    /// same empty asset list.
    private func assembledOmissions() -> [SWFOmission] {
        var result = omissionOrder.compactMap { key -> SWFOmission? in
            guard let value = omissions[key] else { return nil }
            return SWFOmission(
                what: key.what, reason: key.reason, count: value.count,
                byteCount: value.byteCount, detail: value.detail
            )
        }

        for (code, value) in census {
            let tag = SWFTagCode(rawValue: code)
            let reason: SWFOmission.Reason
            switch tag.kind {
            case .vectorOrTimeline: reason = .vectorArtwork
            case .script: reason = .script
            case .unrecognized: reason = .unrecognizedTag
            case .media, .structural: continue
            }
            result.append(
                SWFOmission(
                    what: tag.description, reason: reason, count: value.count,
                    byteCount: value.byteCount,
                    detail: reason == .script
                        ? "ActionScript bytecode. Lathe does not execute it, on any platform."
                        : nil
                )
            )
        }

        return result.sorted {
            $0.byteCount == $1.byteCount ? $0.what < $1.what : $0.byteCount > $1.byteCount
        }
    }

    private func assembledCensus() -> [SWFTagCensus] {
        census
            .map { code, value in
                SWFTagCensus(
                    code: code, name: SWFTagCode(rawValue: code).specificationName,
                    count: value.count, byteCount: value.byteCount
                )
            }
            .sorted { $0.count == $1.count ? $0.code < $1.code : $0.count > $1.count }
    }

    /// The tags that actually *carry* media bytes.
    ///
    /// Deliberately not "every tag classified as media": `StartSound` references
    /// a sound and contains none, and `JPEGTables` on its own is a table with no
    /// image. A file holding only those two has no media in it, and saying
    /// otherwise would turn the verdict into a lie in the one case where the
    /// verdict has to be trusted.
    private static let mediaBearingTagCodes: Set<UInt16> = [
        SWFTagCode.defineBits.rawValue,
        SWFTagCode.defineSound.rawValue,
        SWFTagCode.soundStreamBlock.rawValue,
        SWFTagCode.defineBitsLossless.rawValue,
        SWFTagCode.defineBitsJPEG2.rawValue,
        SWFTagCode.defineBitsJPEG3.rawValue,
        SWFTagCode.defineBitsLossless2.rawValue,
        SWFTagCode.defineVideoStream.rawValue,
        SWFTagCode.videoFrame.rawValue,
        SWFTagCode.defineBinaryData.rawValue,
        SWFTagCode.defineBitsJPEG4.rawValue,
    ]

    private func verdict() -> SWFVerdict {
        if !assets.isEmpty { return .mediaRecovered }

        let mediaTags = census.filter { Self.mediaBearingTagCodes.contains($0.key) }
            .reduce(0) { $0 + $1.value.count }
        if mediaTags > 0 { return .mediaFoundButUnrecoverable }

        var vectorOrScript = 0
        var unrecognised = 0
        for (code, value) in census {
            switch SWFTagCode(rawValue: code).kind {
            case .vectorOrTimeline, .script: vectorOrScript += value.count
            case .unrecognized: unrecognised += value.count
            case .media, .structural: break
            }
        }
        if vectorOrScript > 0 { return .vectorOrScriptOnly }
        if unrecognised > 0 { return .unrecognizedContent }
        return .empty
    }
}
