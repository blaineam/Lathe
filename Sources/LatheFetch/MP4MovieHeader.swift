import CoreMedia
import Foundation

/// Reads the duration an MPEG-4 file declares about itself.
///
/// ## Why this exists at all
///
/// `AVFoundation` mistimes YouTube's fragmented MP4 streams, and by exactly a
/// factor of two. Every DASH video-only rendition it serves comes back with
/// each sample twice as long as the file says it is, so a nineteen-second clip
/// reads as thirty-eight seconds with its last frame held through the second
/// half, and a ten-minute video reads as twenty-one minutes.
///
/// The files themselves are not wrong. On a real example every figure in the
/// container agrees, and agrees with reality:
///
/// ```
/// mvhd  timescale=15360 duration=290816   ->  18.933s
/// mdhd  timescale=15360 duration=290816   ->  18.933s
/// elst  segment_duration=290816
/// sidx  timescale=15360 total=290816      ->  18.933s
/// tfhd  default_sample_duration=1024      ->  15fps at that timescale
/// trun  284 samples, no per-sample durations
/// 284 × 1024 = 290816                     ->  18.933s
/// ```
///
/// `AVAssetReader` hands back those samples at 2048 ticks each. The same file
/// fetched with `curl` byte-for-byte reads the same way, so this is not
/// something the downloader is doing to it.
///
/// So the movie header is read here directly. It is the file's own statement
/// of its length, it is four fields at a known offset, and it is the only
/// thing in the picture that is demonstrably right.
///
/// ## What is deliberately not done
///
/// This is not a demuxer and must not grow into one. It reads `moov/mvhd` and
/// stops. Anything that needs the samples still goes through `AVFoundation`,
/// which is doing the hard part correctly — it is only the timing that needs a
/// second opinion.
enum MP4MovieHeader {

    /// The duration in `moov/mvhd`, or `nil` if this is not an MPEG-4 file or
    /// has no movie header.
    ///
    /// Reads box headers and seeks past the payloads, so the cost is a handful
    /// of small reads regardless of whether the file is four megabytes or four
    /// gigabytes. `moov` is at the front in every fragmented file — it has to
    /// be, since a player needs it before the first fragment — but this does
    /// not assume that and will walk to the end if it must.
    static func declaredDuration(of url: URL) -> CMTime? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return nil }
        guard let moov = findBox("moov", in: handle, from: 0, to: end) else { return nil }
        guard let mvhd = findBox("mvhd", in: handle, from: moov.contentStart, to: moov.end) else {
            return nil
        }

        try? handle.seek(toOffset: mvhd.contentStart)
        // Version 0 puts 32-bit creation and modification times before the
        // timescale; version 1 puts 64-bit ones. Everything after is at a
        // fixed offset from there.
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return nil }
        let version = head[head.startIndex]

        let skip: UInt64 = version == 1 ? 16 : 8
        try? handle.seek(toOffset: mvhd.contentStart + 4 + skip)

        guard let timescaleData = try? handle.read(upToCount: 4), timescaleData.count == 4 else {
            return nil
        }
        let timescale = beUInt32(timescaleData)
        guard timescale > 0 else { return nil }

        let duration: UInt64
        if version == 1 {
            guard let d = try? handle.read(upToCount: 8), d.count == 8 else { return nil }
            duration = beUInt64(d)
        } else {
            guard let d = try? handle.read(upToCount: 4), d.count == 4 else { return nil }
            let value = beUInt32(d)
            // 0xFFFFFFFF is the "unknown duration" sentinel a live or
            // still-being-written file uses. It is not a length.
            if value == 0xFFFF_FFFF { return nil }
            duration = UInt64(value)
        }
        guard duration > 0, duration < UInt64(Int64.max) else { return nil }

        return CMTime(value: CMTimeValue(duration), timescale: CMTimeScale(timescale))
    }

    // MARK: - Boxes

    private struct Box {
        let contentStart: UInt64
        let end: UInt64
    }

    /// Walks the boxes between two offsets looking for one by name.
    private static func findBox(
        _ name: String, in handle: FileHandle, from start: UInt64, to end: UInt64
    ) -> Box? {
        var offset = start
        while offset + 8 <= end {
            try? handle.seek(toOffset: offset)
            guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return nil }

            var size = UInt64(beUInt32(header.prefix(4)))
            var contentStart = offset + 8
            let kind = String(decoding: header[header.startIndex + 4..<header.startIndex + 8],
                              as: UTF8.self)

            if size == 1 {
                // A 64-bit size, carried in the eight bytes after the name.
                guard let large = try? handle.read(upToCount: 8), large.count == 8 else { return nil }
                size = beUInt64(large)
                contentStart = offset + 16
            } else if size == 0 {
                // "To the end of the file", which is legal for the last box.
                size = end - offset
            }
            // A size that does not cover its own header means the file is
            // damaged; walking on from here would read whatever happened to
            // follow as if it were a box.
            guard size >= 8, offset + size <= end else { return nil }

            if kind == name { return Box(contentStart: contentStart, end: offset + size) }
            offset += size
        }
        return nil
    }

    /// Big-endian, over exactly the first four bytes.
    ///
    /// The `prefix` is not decoration. Reading a box header means reading
    /// eight bytes — a size and a name — and handing all eight to this
    /// folded the name into the size and produced a garbage length for
    /// every box in the file, so nothing was ever found.
    private static func beUInt32(_ data: Data) -> UInt32 {
        data.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func beUInt64(_ data: Data) -> UInt64 {
        data.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
