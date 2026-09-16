import Foundation
import LatheCore
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(PDFKit)
import PDFKit
#endif

/// Reads a file's metadata into the one normalised model.
///
/// Translation, not copying. Each store spells the same fact differently — an
/// episode title is `©nam` in an MP4, `TIT2` in an MP3 and `Title` in a PDF —
/// so reading means mapping the store's vocabulary onto ``MediaMetadata`` and
/// keeping whatever did not map under ``MediaMetadata/custom`` so a
/// read-modify-write does not quietly discard it.
public struct MetadataReader: Sendable {

    public init() {}

    /// Everything the file says about itself.
    public func read(_ url: URL) async throws -> MediaMetadata {
        try await read(MediaSource(url))
    }

    /// Reads media that may be on disk or at a plain URL.
    ///
    /// The MP4 family is **streamed**: AVFoundation reads the container's
    /// metadata by range request, so the atoms come back without the samples.
    /// Everything else is staged to a temporary file first, because ImageIO,
    /// PDFKit and the ID3 parser all need a file — and that is a real download,
    /// bounded by `limits`.
    ///
    /// The store is detected from the first bytes either way, which for a remote
    /// source is one small range request rather than a guess from the URL's
    /// extension. A URL that ends in `.mp4` and serves a JPEG is read as a JPEG.
    public func read(
        _ source: MediaSource,
        transport: any MediaDataTransport = URLSessionMediaTransport(),
        limits: RemoteLimits = .standard
    ) async throws -> MediaMetadata {
        guard source.isRemote else {
            return try await readLocal(source.url)
        }

        let head = try await transport.range(source.url, offset: 0, length: 16, limits: limits)
        let store = try MetadataStore.detect(leadingBytes: [UInt8](head), name: source.suggestedName)

        if store == .iTunesAtoms {
            // Streamed. The metadata atoms live in `moov`, and AVFoundation
            // fetches only what it needs to read them.
            return try await readAVFoundation(source.url)
        }
        return try await source.withLocalFile(transport: transport, limits: limits) { staged in
            try await readLocal(staged)
        }
    }

    private func readLocal(_ url: URL) async throws -> MediaMetadata {
        try MetaFiles.requireReadableFile(at: url)
        switch try MetadataStore.detect(at: url) {
        case .iTunesAtoms:
            return try await readAVFoundation(url)
        case .id3:
            // Read through this module's own parser rather than AVFoundation.
            // The writer had to exist regardless, and reading through it means
            // the two agree by construction — and that a file whose audio frames
            // are damaged still reports its title, which is exactly the file
            // someone is trying to fix.
            return try ID3File.read(url)
        case .imageProperties:
            return try readImage(url)
        case .pdfInfo:
            return try readPDF(url)
        }
    }

    /// Which store the file uses, without reading it.
    public func store(of url: URL) throws -> MetadataStore {
        try MetadataStore.detect(at: url)
    }

    // MARK: - MP4 family and MP3

    #if canImport(AVFoundation)
    private func readAVFoundation(_ url: URL) async throws -> MediaMetadata {
        let asset = AVURLAsset(url: url)
        let items: [AVMetadataItem]
        do {
            items = try await asset.load(.metadata)
        } catch {
            throw LatheError.readFailed(
                path: url.lastPathComponent, reason: (error as NSError).localizedDescription
            )
        }

        var meta = MediaMetadata()
        var show = ShowInfo()
        var track = TrackInfo()

        // 3GPP user data is read last, and only into fields the iTunes tags
        // left empty: AVFoundation often writes both spellings of one fact,
        // and reading both would list an artist twice.
        let isoFirst: (AVMetadataItem) -> Bool = { $0.identifier?.rawValue.hasPrefix("uiso/") == true }
        let ordered = items.filter { !isoFirst($0) } + items.filter(isoFirst)
        var iso = MediaMetadata()

        for item in ordered {
            guard let key = try? await AVMetadataItemKey(item: item) else { continue }
            if isoFirst(item) {
                let value = try await item.stringValue()
                switch key {
                case .title: iso.title = iso.title ?? value
                case .summary: iso.summary = iso.summary ?? value
                case .artist: if let value { iso.creators.append(value) }
                case .genre: iso.genre = iso.genre ?? value
                case .copyright: iso.copyrightNotice = iso.copyrightNotice ?? value
                case .albumName: if let value, track.albumName == nil { track.albumName = value }
                default: break
                }
                continue
            }
            switch key {
            case .title: meta.title = try await item.stringValue()
            case .summary: meta.summary = try await item.stringValue()
            case .longDescription: meta.longDescription = try await item.stringValue()
            case .artist:
                if let value = try await item.stringValue() { meta.creators.append(value) }
            case .genre: meta.genre = try await item.stringValue()
            case .comment: meta.comment = try await item.stringValue()
            case .copyright: meta.copyrightNotice = try await item.stringValue()
            case .creationDate: meta.date = try await item.dateValue()
            case .mediaKind:
                if let raw = try await item.intValue() { meta.kind = MediaKind(rawValue: raw) }
            case .artwork:
                if let data = try await item.dataValue(), let art = Artwork(sniffing: data) {
                    meta.artwork.append(art)
                }
            case .seriesName: show.seriesName = try await item.stringValue()
            case .seasonNumber: show.seasonNumber = try await item.intValue()
            case .episodeNumber: show.episodeNumber = try await item.intValue()
            case .episodeID: show.episodeID = try await item.stringValue()
            case .network: show.network = try await item.stringValue()
            case .albumName: track.albumName = try await item.stringValue()
            case .albumArtist: track.albumArtist = try await item.stringValue()
            case .composer: track.composer = try await item.stringValue()
            case .trackNumber: track.trackNumber = try await item.intValue()
            case .discNumber: track.discNumber = try await item.intValue()
            case .compilation: track.isCompilation = (try await item.intValue()).map { $0 != 0 }
            case .unmapped(let identifier):
                if let value = try await item.stringValue() { meta.custom[identifier] = value }
            }
        }

        meta.title = meta.title ?? iso.title
        meta.summary = meta.summary ?? iso.summary
        meta.genre = meta.genre ?? iso.genre
        meta.copyrightNotice = meta.copyrightNotice ?? iso.copyrightNotice
        if meta.creators.isEmpty { meta.creators = iso.creators }

        if show != ShowInfo() { meta.show = show }
        if track != TrackInfo() { meta.track = track }
        return meta
    }
    #else
    private func readAVFoundation(_ url: URL) async throws -> MediaMetadata {
        throw LatheError.decodeUnavailable(format: "container metadata needs AVFoundation")
    }
    #endif

    // MARK: - Stills

    #if canImport(ImageIO)
    private func readImage(_ url: URL) throws -> MediaMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "no image properties")
        }

        var meta = MediaMetadata()
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        meta.title = (iptc[kCGImagePropertyIPTCObjectName] as? String)
            ?? (tiff[kCGImagePropertyTIFFDocumentName] as? String)
        meta.summary = (iptc[kCGImagePropertyIPTCCaptionAbstract] as? String)
            ?? (tiff[kCGImagePropertyTIFFImageDescription] as? String)
        if let artist = (tiff[kCGImagePropertyTIFFArtist] as? String)
            ?? (iptc[kCGImagePropertyIPTCByline] as? String) {
            meta.creators = [artist]
        }
        meta.copyrightNotice = (tiff[kCGImagePropertyTIFFCopyright] as? String)
            ?? (iptc[kCGImagePropertyIPTCCopyrightNotice] as? String)
        meta.comment = exif[kCGImagePropertyExifUserComment] as? String

        if let stamp = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (tiff[kCGImagePropertyTIFFDateTime] as? String) {
            meta.date = Self.exifFormatter.date(from: stamp)
        }

        if let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
           let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            // EXIF stores magnitude and hemisphere separately, so a southern or
            // western coordinate read without its reference comes back mirrored
            // onto the wrong continent.
            let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
            let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
            var altitude = gps[kCGImagePropertyGPSAltitude] as? Double
            if let reference = gps[kCGImagePropertyGPSAltitudeRef] as? Int, reference == 1 {
                altitude = altitude.map(-)
            }
            meta.location = Location(
                latitude: south ? -latitude : latitude,
                longitude: west ? -longitude : longitude,
                altitude: altitude
            )
        }

        return meta
    }
    #else
    private func readImage(_ url: URL) throws -> MediaMetadata {
        throw LatheError.decodeUnavailable(format: "still metadata needs ImageIO")
    }
    #endif

    /// EXIF's own timestamp spelling, which is not ISO 8601 and is not
    /// localised. A fixed POSIX locale and UTC keep a read on one machine equal
    /// to a read on another.
    static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    // MARK: - PDF

    #if canImport(PDFKit)
    private func readPDF(_ url: URL) throws -> MediaMetadata {
        guard let document = PDFDocument(url: url) else {
            throw LatheError.invalidInput(
                reason: "\(url.lastPathComponent) is not a PDF PDFKit can open"
            )
        }
        let attributes = document.documentAttributes ?? [:]
        var meta = MediaMetadata()
        meta.title = attributes[PDFDocumentAttribute.titleAttribute] as? String
        meta.summary = attributes[PDFDocumentAttribute.subjectAttribute] as? String
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String {
            meta.creators = [author]
        }
        meta.date = attributes[PDFDocumentAttribute.creationDateAttribute] as? Date
        if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] {
            // PDFKit hands keywords back as an array on read and expects one on
            // write, but a PDF written by anything else stores a single string.
            if let list = keywords as? [String] {
                meta.custom["pdf.Keywords"] = list.joined(separator: ", ")
            } else if let single = keywords as? String {
                meta.custom["pdf.Keywords"] = single
            }
        }
        if let creator = attributes[PDFDocumentAttribute.creatorAttribute] as? String {
            meta.custom["pdf.Creator"] = creator
        }
        if let producer = attributes[PDFDocumentAttribute.producerAttribute] as? String {
            meta.custom["pdf.Producer"] = producer
        }
        return meta
    }
    #else
    private func readPDF(_ url: URL) throws -> MediaMetadata {
        throw LatheError.decodeUnavailable(format: "PDF metadata needs PDFKit")
    }
    #endif
}
