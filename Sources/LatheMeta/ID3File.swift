import Foundation
import LatheCore

/// Reading and rewriting the tags on an MPEG audio file.
///
/// ## Why this is not a container rewrite
///
/// An MP4's metadata lives inside the container, so editing it means asking the
/// container's writer to produce a new file. An MP3 has no container: it is a
/// run of MPEG frames with tags bolted to either end. Editing it is therefore
/// simpler and stronger — emit a new tag, then copy the audio bytes across
/// verbatim. Nothing re-muxes and nothing parses a frame.
///
/// ## The trailing tag nobody remembers
///
/// An ID3v1 tag is 128 bytes at the very end of the file, and it is the reason
/// a file can show one title in a modern player and a different one in an old
/// device or a car stereo. Leaving a stale v1 tag in place after rewriting v2
/// would produce exactly that split, so it is removed rather than left to
/// disagree — and the removal is reported, because it is a real change to the
/// file beyond the one that was asked for.
///
/// Writing a fresh v1 tag instead was the alternative and is worse: its fields
/// are fixed-width and truncate at 30 characters, so it would be a second,
/// lossy copy of the truth, guaranteed to drift the moment anything edits one
/// and not the other.
enum ID3File {

    /// What a file's tags look like, and where the audio starts and ends.
    struct Layout {
        /// The ID3v2 tag at the front, if any.
        var tag: ID3Tag?
        /// The byte range holding the MPEG frames.
        var audio: Range<Int>
        /// Whether a 128-byte ID3v1 tag sits at the end.
        var hasTrailingV1: Bool
    }

    static func layout(of data: Data, name: String) throws -> Layout {
        let tag = try ID3Tag.parse(data, name: name)
        let start = tag?.byteCount ?? 0

        var end = data.count
        // "TAG" 128 bytes from the end is an ID3v1 tag. Checked by position and
        // magic together: three bytes of audio can spell TAG by coincidence, but
        // not at exactly that offset.
        if data.count >= start + 128 {
            let offset = data.index(data.startIndex, offsetBy: data.count - 128)
            let magic = data[offset..<data.index(offset, offsetBy: 3)]
            if Array(magic) == Array("TAG".utf8) { end = data.count - 128 }
        }
        guard start <= end else {
            throw LatheError.invalidInput(reason: "\(name) has overlapping ID3 tags")
        }
        return Layout(tag: tag, audio: start..<end, hasTrailingV1: end != data.count)
    }

    /// The file's metadata.
    static func read(_ url: URL) throws -> MediaMetadata {
        let data = try contents(of: url)
        guard let tag = try layout(of: data, name: url.lastPathComponent).tag else {
            return MediaMetadata()
        }
        return ID3Metadata.metadata(from: tag)
    }

    /// Writes `source` to `destination` carrying `metadata`, copying every audio
    /// byte untouched.
    ///
    /// - Returns: the fields ID3 could not hold, and whether a trailing v1 tag
    ///   was removed.
    static func write(
        _ metadata: MediaMetadata, source: URL, destination: URL
    ) throws -> (bytes: UInt64, unrepresented: [String], removedTrailingV1: Bool) {
        let data = try contents(of: source)
        let layout = try layout(of: data, name: source.lastPathComponent)

        let (frames, unrepresented) = ID3Metadata.frames(for: metadata)
        // Frames the model has no name for are carried across from the source
        // rather than discarded, so editing a title does not strip a tagger's
        // replay-gain or MusicBrainz frames on the way past.
        let carried = (layout.tag?.frames ?? []).filter { frame in
            if case .raw = frame.payload { return !isRepresented(frame.id) }
            return false
        }

        let tag = ID3Tag(frames: frames + carried, byteCount: 0)
        let header = tag.frames.isEmpty ? Data() : tag.serialise()
        let audio = data.subdata(in: layout.audio)
        guard !audio.isEmpty else {
            throw LatheError.invalidInput(
                reason: "\(source.lastPathComponent) has no audio outside its tags"
            )
        }

        let bytes = try MetaFiles.writingAtomically(
            to: destination,
            pathExtension: destination.pathExtension.isEmpty ? "mp3" : destination.pathExtension,
            stage: "metadata-id3"
        ) { scratch in
            var out = header
            out.append(audio)
            do {
                try out.write(to: scratch, options: .atomic)
            } catch {
                throw LatheError.writeFailed(
                    path: destination.lastPathComponent,
                    reason: (error as NSError).localizedDescription
                )
            }
        }
        return (bytes, unrepresented, layout.hasTrailingV1)
    }

    /// Whether a frame ID is one the model itself writes, and therefore must not
    /// also be carried across from the source — two `TIT2` frames in one tag is
    /// a file whose title depends on which one the reader looks at first.
    private static func isRepresented(_ id: String) -> Bool {
        [
            "TIT2", "TIT3", "TPE1", "TPE2", "TALB", "TCON", "TCOP", "TCOM",
            "TRCK", "TPOS", "TCMP", "TDRC", "TYER", "TDAT", "COMM", "APIC", "TXXX",
        ].contains(id)
    }

    private static func contents(of url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw LatheError.readFailed(
                path: url.lastPathComponent, reason: (error as NSError).localizedDescription
            )
        }
    }
}
