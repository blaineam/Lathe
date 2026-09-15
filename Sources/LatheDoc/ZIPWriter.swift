import Foundation
import LatheCore

/// Writes a ZIP archive from members whose payloads are already in their stored
/// form.
///
/// ## Why the payload is pre-formed
///
/// Rearranging a comic archive should not re-encode its pages. The entries are
/// JPEG or PNG images that were compressed once; running them through deflate
/// again costs CPU and saves nothing — already-compressed data does not deflate
/// — and decompressing them to re-compress them would risk changing bytes that
/// had no reason to change. So a rewrite copies each payload verbatim, in
/// whatever method the source used, and carries the source's CRC and timestamps
/// with it. The archive's *index* is what an edit rewrites; the pages are moved,
/// not remade.
///
/// That is also why ``Member`` carries a checksum rather than computing one:
/// for a copied entry the correct CRC is already recorded in the source
/// archive, and recomputing it would mean inflating a payload purely to restate
/// a number that is on disk.
///
/// ## What it does not write
///
/// No ZIP64 records, no encryption, no data descriptors. An archive that needs
/// ZIP64 is **refused by name** rather than written wrongly: the fields would
/// silently wrap, and a comic that reports three pages because its offsets
/// exceeded 4 GB is a worse outcome than a clear refusal. ``ZIPDirectory``
/// *reads* ZIP64 for the same reason it exists — archives in the wild have it —
/// but nothing here produces one.
enum ZIPWriter {

    /// One entry to write, with its payload already in `method` form.
    struct Member {
        /// The stored path, separators included. Written UTF-8 with the
        /// language-encoding flag set, so a non-ASCII name survives.
        var name: String
        /// The payload exactly as it will sit in the archive — deflated if
        /// `method` is 8, raw if `method` is 0.
        var payload: Data
        /// `0` stored or `8` deflate. Copied from the source for a copied entry.
        var method: UInt16
        /// CRC-32 of the *uncompressed* bytes.
        var crc32: UInt32
        /// Size of the uncompressed bytes, which for a stored entry equals the
        /// payload's size.
        var uncompressedSize: UInt64
        var modificationTime: UInt16
        var modificationDate: UInt16
        var externalAttributes: UInt32

        /// A member holding data that is not compressed at all.
        ///
        /// The right choice for an image being added to a comic archive: a JPEG
        /// or PNG is already compressed, so deflating it spends time to make it
        /// very slightly larger.
        static func stored(
            name: String,
            data: Data,
            modified: Date = Date(),
            externalAttributes: UInt32 = 0
        ) -> Member {
            let (time, date) = dosTimestamp(from: modified)
            return Member(
                name: name,
                payload: data,
                method: 0,
                crc32: CRC32.checksum(data),
                uncompressedSize: UInt64(data.count),
                modificationTime: time,
                modificationDate: date,
                externalAttributes: externalAttributes
            )
        }
    }

    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralFileHeaderSignature: UInt32 = 0x0201_4B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50

    /// Bit 11: the name is UTF-8. Set unconditionally — Foundation gives UTF-8
    /// and the flag is how a reader knows not to treat it as code page 437.
    private static let utf8NameFlag: UInt16 = 1 << 11

    /// The largest value any 32-bit ZIP field can hold. Beyond it an archive
    /// needs ZIP64, which this writer refuses rather than wraps.
    private static let fieldLimit: UInt64 = 0xFFFF_FFFE
    private static let entryLimit = 65_534

    /// Writes `members` to `url`, in the order given.
    ///
    /// Order is the whole point for a comic archive, but note that most readers
    /// sort by *name* rather than trusting archive order — see
    /// ``ComicArchiveEditor`` for why an edit renumbers.
    static func write(_ members: [Member], to url: URL, name: String) throws {
        guard !members.isEmpty else {
            throw LatheError.invalidInput(reason: "an archive must have at least one entry")
        }
        guard members.count <= entryLimit else {
            throw LatheError.invalidInput(
                reason: "\(members.count) entries needs a ZIP64 archive, which this writer "
                    + "does not produce (limit \(entryLimit))"
            )
        }

        var archive = Data()
        var directory = Data()
        var offsets: [UInt64] = []
        offsets.reserveCapacity(members.count)

        for member in members {
            let offset = UInt64(archive.count)
            guard offset <= fieldLimit else {
                throw LatheError.invalidInput(
                    reason: "the archive passed 4 GB at entry \(member.name); that needs ZIP64, "
                        + "which this writer does not produce"
                )
            }
            guard UInt64(member.payload.count) <= fieldLimit,
                  member.uncompressedSize <= fieldLimit
            else {
                throw LatheError.invalidInput(
                    reason: "entry \(member.name) is larger than 4 GB; that needs ZIP64, which "
                        + "this writer does not produce"
                )
            }
            offsets.append(offset)
            archive.append(localHeader(for: member))
            archive.append(member.payload)
        }

        for (member, offset) in zip(members, offsets) {
            directory.append(centralHeader(for: member, at: offset))
        }

        let directoryOffset = UInt64(archive.count)
        guard directoryOffset <= fieldLimit else {
            throw LatheError.invalidInput(
                reason: "the archive passed 4 GB before its index; that needs ZIP64, which this "
                    + "writer does not produce"
            )
        }
        archive.append(directory)
        archive.append(endOfCentralDirectory(
            entryCount: UInt16(members.count),
            directorySize: UInt32(directory.count),
            directoryOffset: UInt32(directoryOffset)
        ))

        do {
            try archive.write(to: url, options: .atomic)
        } catch {
            throw LatheError.writeFailed(path: name, reason: (error as NSError).localizedDescription)
        }
    }

    // MARK: - Records

    private static func localHeader(for member: Member) -> Data {
        let nameBytes = Data(member.name.utf8)
        var out = Data()
        out.appendLE(localFileHeaderSignature)
        out.appendLE(UInt16(20))                       // version needed: 2.0, deflate
        out.appendLE(utf8NameFlag)                     // never bit 3: sizes are known here
        out.appendLE(member.method)
        out.appendLE(member.modificationTime)
        out.appendLE(member.modificationDate)
        out.appendLE(member.crc32)
        out.appendLE(UInt32(member.payload.count))
        out.appendLE(UInt32(member.uncompressedSize))
        out.appendLE(UInt16(nameBytes.count))
        out.appendLE(UInt16(0))                        // no extra field
        out.append(nameBytes)
        return out
    }

    private static func centralHeader(for member: Member, at offset: UInt64) -> Data {
        let nameBytes = Data(member.name.utf8)
        var out = Data()
        out.appendLE(centralFileHeaderSignature)
        out.appendLE(UInt16(0x031E))                   // made by: Unix, 3.0
        out.appendLE(UInt16(20))
        out.appendLE(utf8NameFlag)
        out.appendLE(member.method)
        out.appendLE(member.modificationTime)
        out.appendLE(member.modificationDate)
        out.appendLE(member.crc32)
        out.appendLE(UInt32(member.payload.count))
        out.appendLE(UInt32(member.uncompressedSize))
        out.appendLE(UInt16(nameBytes.count))
        out.appendLE(UInt16(0))                        // extra
        out.appendLE(UInt16(0))                        // comment
        out.appendLE(UInt16(0))                        // disk number
        out.appendLE(UInt16(0))                        // internal attributes
        out.appendLE(member.externalAttributes)
        out.appendLE(UInt32(offset))
        out.append(nameBytes)
        return out
    }

    private static func endOfCentralDirectory(
        entryCount: UInt16, directorySize: UInt32, directoryOffset: UInt32
    ) -> Data {
        var out = Data()
        out.appendLE(endOfCentralDirectorySignature)
        out.appendLE(UInt16(0))                        // this disk
        out.appendLE(UInt16(0))                        // disk with the directory
        out.appendLE(entryCount)
        out.appendLE(entryCount)
        out.appendLE(directorySize)
        out.appendLE(directoryOffset)
        out.appendLE(UInt16(0))                        // comment length
        return out
    }

    /// MS-DOS packed time and date, which is what a ZIP header stores.
    ///
    /// Two-second resolution and a 1980 epoch, both from the format. A date
    /// before 1980 cannot be represented and is clamped to it rather than
    /// wrapping into a plausible-looking wrong year.
    static func dosTimestamp(from date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | ((c.second ?? 0) / 2))
        let day = UInt16((year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

/// CRC-32 as ZIP specifies it: the reflected polynomial, which is the same one
/// zlib uses.
///
/// Present because adding a *new* page to an archive means checksumming bytes
/// that no archive has recorded yet. Copying an existing page does not need it —
/// that CRC comes from the source — so this runs over new data only.
enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            return value
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) {
                crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
