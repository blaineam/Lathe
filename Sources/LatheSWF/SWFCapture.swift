import Foundation
import LatheCore

/// Recovers the standard media embedded in an Adobe Flash `.swf`.
///
/// ```swift
/// let report = try SWFCapture().extract(movie, to: outputDirectory)
/// print(report.summary)
/// // intro.swf: SWF 6, zlib (CWS), 550×400, 240 frames at 12.00 fps —
/// // recovered 14 images, 2 sounds.
/// ```
///
/// ## What this is, and the much larger thing it is not
///
/// **This does not play, render, or convert a Flash movie.** It cannot produce
/// frames, an animated image, or a video of one, and no amount of further work
/// on *this* module would get there. That is worth stating first because it is
/// the thing people want from a `.swf`, and because the gap is not a matter of
/// polish:
///
/// - A SWF's animation is **vector artwork driven by a display list**. Rendering
///   one frame means parsing shape records (edge and style change records, fill
///   and line style arrays, a bit-packed coordinate encoding that changes
///   between four tag versions), resolving morph shapes by interpolating between
///   two shape definitions, maintaining a depth-ordered display list across
///   frames with transforms and colour transforms, applying clipping layers,
///   blend modes and filters, and rasterising all of it with a non-zero winding
///   rule. That is a renderer, and a renderer is a project measured in
///   person-years — Ruffle, which does it well, is a very large piece of
///   software with a substantial team.
/// - Much Flash content does not *have* a fixed timeline to render. It is
///   **driven by ActionScript**, in either of two unrelated virtual machines
///   (AVM1's stack machine, AVM2's ABC bytecode), reaching a runtime library of
///   several hundred classes. Executing untrusted bytecode from a dead platform
///   inside somebody's photo application is not a feature with a defensible
///   risk story, whatever it would cost to build.
///
/// So this module does the tractable, useful thing instead, and says plainly
/// what it left behind. **Most of what anybody actually wants out of an old SWF
/// is the art and the audio somebody put into it** — the photographs, the
/// painted backgrounds, the sprite sheets, the music — and those are stored as
/// ordinary JPEG, PNG, GIF, MP3 and PCM inside a tag stream that can be walked
/// without understanding a single thing about Flash.
///
/// ## What comes out
///
/// | Tag | Result |
/// |---|---|
/// | `DefineBits` + `JPEGTables` | `.jpg`, reassembled from the two halves |
/// | `DefineBitsJPEG2` | `.jpg`, `.png` or `.gif` — whatever it really held |
/// | `DefineBitsJPEG3` / `JPEG4` | `.png`, JPEG composed with its alpha channel |
/// | `DefineBitsLossless` / `2` | `.png`, decoded from five possible pixel layouts |
/// | `DefineSound` (MP3) | `.mp3` |
/// | `DefineSound` (PCM) | `.wav` |
/// | `SoundStreamBlock` (MP3) | one `.mp3` per timeline |
/// | `DefineBinaryData` | the embedded file, named by what it actually is |
///
/// And what does not, each named in ``SWFCaptureReport/omissions``: ADPCM,
/// Nellymoser and Speex audio; Sorenson H.263, VP6 and Screen video; every
/// shape, font, text and morph tag; both flavours of ActionScript.
///
/// ## Hostile input is the design assumption
///
/// A `.swf` is a binary file of unknown provenance from a platform that has been
/// dead for years and is no longer receiving security attention anywhere. This
/// module therefore treats every length in the file as a claim to be checked
/// rather than a number to act on, bounds-checks every read, caps every
/// allocation the file could otherwise size (see ``SWFLimits``), refuses to move
/// its cursor backwards, and limits sprite recursion so that a crafted file
/// cannot exhaust the stack. A malformed file produces a thrown
/// ``LatheError``, never a crash and never a loop.
///
/// One distinction inside that: **a tag whose framing is broken is fatal, and a
/// tag whose contents are broken is not.** Once a declared length does not fit,
/// the stream's framing is lost and everything found afterwards is noise
/// presented as data, so the walk throws. But a single bitmap that inflates to
/// the wrong size tells you nothing about the next tag, so it is recorded as a
/// malformed omission and the walk goes on — which is what lets a partially
/// corrupt file still give up its eleven good images.
public struct SWFCapture: Sendable {

    public let limits: SWFLimits

    public init(limits: SWFLimits = .default) {
        self.limits = limits
    }

    // MARK: - Cheap questions

    /// How the file is compressed, and the SWF version it declares — read from
    /// the first four bytes, decompressing nothing.
    ///
    /// Worth its own entry point because ``SWFCompression/lzma`` is the one
    /// input this module refuses, and a caller that wants to route those
    /// elsewhere should not have to provoke an error to find out.
    public func signature(of url: URL) throws -> (compression: SWFCompression, version: UInt8) {
        let name = url.lastPathComponent
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw LatheError.readFailed(path: name, reason: (error as NSError).localizedDescription)
        }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: SWFReader.plainHeaderLength)) ?? Data()
        return try SWFReader.signature(of: head, name: name)
    }

    /// Just the header: version, compression, stage size, frame rate and frame
    /// count.
    ///
    /// Cheap on purpose. It reads the first 64 KB of the file and tries to parse
    /// a header out of that, which for an uncompressed movie needs about twenty
    /// bytes and for a compressed one needs whatever the first deflate block
    /// yields — so a 40 MB movie costs the same as a 40 KB one. It falls back to
    /// reading the whole file only if the prefix was not enough, so the saving is
    /// an optimisation rather than a new way to fail.
    ///
    /// The frame rate and frame count are what a renderer needs to choose a
    /// capture rate and a length, which is what this exists for.
    ///
    /// - Throws: the same errors as ``inspect(_:)``, including
    ///   ``LatheError/decodeUnavailable(format:)`` for an LZMA file.
    public func header(of url: URL) throws -> SWFHeader {
        let name = url.lastPathComponent
        if let prefix = try? Self.readPrefix(of: url, byteCount: 64 * 1024),
           let header = try? SWFReader.open(prefix, name: name, limits: limits).header
        {
            return header
        }
        return try SWFReader.open(url, name: name, limits: limits).header
    }

    private static func readPrefix(of url: URL, byteCount: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: byteCount) ?? Data()
    }

    // MARK: - Inspecting

    /// Finds everything a capture would recover, and writes nothing.
    ///
    /// The returned report is identical to ``extract(_:to:)``'s except that
    /// every ``SWFAsset/fileName`` is `nil`. That is deliberate and it is not
    /// free: the work is genuinely done — bitmaps are decoded, alpha channels
    /// composed, PNGs encoded — and the bytes are then discarded, so
    /// ``SWFAsset/byteCount`` is the real size of the real file rather than an
    /// estimate, and the two reports agree about what is in the movie.
    ///
    /// Use it to vet a file of unknown provenance *before* letting it create
    /// anything on disk. If you already intend to extract, call
    /// ``extract(_:to:)`` directly rather than both: inspecting first doubles
    /// the decoding.
    public func inspect(_ url: URL) throws -> SWFCaptureReport {
        try run(url, writingTo: nil)
    }

    // MARK: - Extracting

    /// Extracts every recoverable image, sound and embedded file into
    /// `directory`, and writes a `manifest.json` describing the result.
    ///
    /// The directory is created on the first write. Filenames are generated
    /// here — `character-00042.png` — and never derived from the file's
    /// contents: a SWF carries no filenames worth honouring, and generating them
    /// on this side means no payload can influence a path.
    ///
    /// - Returns: the same report that is written to `manifest.json`.
    /// - Throws: ``LatheError/decodeUnavailable(format:)`` for an LZMA (`ZWS`)
    ///   file, ``LatheError/invalidInput(reason:)`` for one that is malformed,
    ///   and ``LatheError/writeFailed(path:reason:)`` if the output cannot be
    ///   written.
    @discardableResult
    public func extract(_ url: URL, to directory: URL) throws -> SWFCaptureReport {
        // The directory is created by the first thing that writes into it —
        // an extracted asset, or the manifest below — rather than up front, so
        // a file that turns out to be LZMA or malformed throws without leaving
        // an empty folder named after it.
        let report = try run(url, writingTo: directory)

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        } catch {
            throw LatheError.writeFailed(
                path: directory.lastPathComponent, reason: (error as NSError).localizedDescription
            )
        }

        let manifest = directory.appendingPathComponent("manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(report).write(to: manifest, options: .atomic)
        } catch {
            throw LatheError.writeFailed(
                path: "manifest.json", reason: (error as NSError).localizedDescription
            )
        }
        return report
    }

    // MARK: - The single pass

    private func run(_ url: URL, writingTo directory: URL?) throws -> SWFCaptureReport {
        let name = url.lastPathComponent
        let (header, tags) = try SWFReader.open(url, name: name, limits: limits)
        return try run(header: header, tags: tags, name: name, writingTo: directory)
    }

    /// The same pass over bytes already in hand. Internal so the test suite can
    /// synthesise a SWF without a filesystem.
    func run(_ data: Data, name: String, writingTo directory: URL?) throws -> SWFCaptureReport {
        let (header, tags) = try SWFReader.open(data, name: name, limits: limits)
        return try run(header: header, tags: tags, name: name, writingTo: directory)
    }

    private func run(
        header: SWFHeader, tags: SWFByteReader, name: String, writingTo directory: URL?
    ) throws -> SWFCaptureReport {
        let collector = SWFCollector(
            header: header, name: name, limits: limits, destination: directory
        )
        var reader = tags
        try SWFTagStream.walk(&reader, limits: limits, name: name) { record in
            try collector.accept(record)
        }
        return try collector.finish()
    }
}
