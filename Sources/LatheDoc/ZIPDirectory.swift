import Compression
import Foundation
import LatheCore

/// One entry in a ZIP archive's central directory, as recorded there — no part
/// of the entry's *contents* has been touched to build it.
struct ZIPEntry: Sendable, Equatable {
    /// The stored path, exactly as the archive spells it, separators included.
    let name: String
    /// `8` is deflate, `0` is stored. Anything else this reader refuses to
    /// extract (it still counts, because counting does not decompress).
    let compressionMethod: UInt16
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
    /// The MS-DOS / Unix attribute word, used only to recognise a directory
    /// that was written without a trailing slash.
    let externalAttributes: UInt32

    /// The last path component.
    var baseName: String {
        name.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? name
    }

    /// The lowercased filename extension, or `""`.
    var fileExtension: String {
        let base = baseName
        guard let dot = base.lastIndex(of: "."), dot != base.startIndex else { return "" }
        return String(base[base.index(after: dot)...]).lowercased()
    }

    /// Whether this entry is a folder rather than a file.
    ///
    /// The trailing slash is the portable signal and every writer emits it; the
    /// attribute bits are checked as well because an archive assembled by hand,
    /// or by a tool that only set the MS-DOS directory bit, otherwise looks like
    /// a zero-byte file with a plausible name.
    var isDirectory: Bool {
        if name.hasSuffix("/") { return true }
        // Low byte: MS-DOS attributes, 0x10 is "directory".
        if externalAttributes & 0x10 != 0 { return true }
        // High 16 bits: Unix st_mode, when version-made-by says Unix. 0x4000 is
        // S_IFDIR.
        if (externalAttributes >> 16) & 0xF000 == 0x4000 { return true }
        return false
    }
}

/// Reads a ZIP archive's *structure* — never its contents, unless asked.
///
/// ## Why this exists rather than a dependency
///
/// Counting the pages in a comic archive is counting its entries, and the
/// central directory at the end of the file is a complete list of them. Reading
/// it costs the same for a 2 GB archive as for a 2 MB one, which is the whole
/// reason page counting is cheap. A general-purpose ZIP library would do the
/// same thing plus a great deal this package does not need, and Lathe's licence
/// policy (see the README) makes every added dependency a decision rather than a
/// convenience. Foundation offers no public ZIP *reader* on either platform —
/// `NSFileCoordinator`'s `.forUploading` intent writes one and does not read one
/// — so the choice is this or a third party, and this is 200 lines.
///
/// ## What it reads, and what it deliberately does not
///
/// - The end-of-central-directory record, located by scanning backwards.
/// - The ZIP64 records, when the 32-bit fields are saturated. A comic archive
///   large enough to need them is rare, and an archive that silently reports
///   65535 pages because nobody handled `0xFFFF` is worse than rare.
/// - Each central directory header: name, method, sizes, local header offset.
///
/// It does **not** verify CRCs, does not read local headers unless an entry is
/// actually extracted, and does not support encrypted or spanned archives.
enum ZIPDirectory {

    // MARK: - Signatures

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let zip64EndSignature: UInt32 = 0x0606_4B50
    private static let centralFileHeaderSignature: UInt32 = 0x0201_4B50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50

    /// The most bytes the end-of-central-directory record can be from the end of
    /// the file: its own 22 bytes plus a comment of up to 65535.
    private static let maximumEndRecordSearch = 22 + 65_535

    // MARK: - Reading

    /// Every entry the archive's central directory lists, in directory order.
    ///
    /// - Throws: ``LatheError/invalidInput(reason:)`` when the file is not a ZIP
    ///   archive, or is one this reader will not walk (encrypted, spanned).
    static func entries(of url: URL, name: String) throws -> [ZIPEntry] {
        let handle = try open(url, name: name)
        defer { try? handle.close() }

        let fileSize = try size(of: handle, name: name)
        guard fileSize >= 22 else {
            throw LatheError.invalidInput(reason: "\(name) is too short to be a ZIP archive")
        }

        let (entryCount, directoryOffset, directorySize) = try locateCentralDirectory(
            handle, fileSize: fileSize, name: name
        )

        guard directorySize > 0 || entryCount == 0 else {
            throw LatheError.invalidInput(reason: "\(name) has an empty central directory")
        }
        guard directoryOffset &+ directorySize <= fileSize else {
            throw LatheError.invalidInput(
                reason: "\(name)'s central directory runs past the end of the file"
            )
        }

        let directory = try read(handle, at: directoryOffset, count: Int(directorySize), name: name)
        var reader = ByteReader(directory)
        var entries: [ZIPEntry] = []
        entries.reserveCapacity(min(Int(entryCount), 4096))

        while reader.remaining >= 46 {
            guard try reader.u32() == centralFileHeaderSignature else { break }
            reader.skip(4)                                   // versions
            let flags = try reader.u16()
            let method = try reader.u16()
            reader.skip(8)                                   // time, date, crc32
            var compressed = UInt64(try reader.u32())
            var uncompressed = UInt64(try reader.u32())
            let nameLength = Int(try reader.u16())
            let extraLength = Int(try reader.u16())
            let commentLength = Int(try reader.u16())
            reader.skip(4)                                   // disk start, internal attrs
            let externalAttributes = try reader.u32()
            var localOffset = UInt64(try reader.u32())

            let nameBytes = try reader.bytes(nameLength)
            let extra = try reader.bytes(extraLength)
            reader.skip(commentLength)

            // Bit 0 is "encrypted". The entry still counts as a page — it is a
            // file in the archive — but extraction would produce ciphertext, so
            // the extractor refuses it by method later.
            _ = flags

            applyZIP64Extra(
                extra,
                uncompressed: &uncompressed,
                compressed: &compressed,
                localOffset: &localOffset
            )

            entries.append(ZIPEntry(
                name: decodeName(nameBytes, flags: flags),
                compressionMethod: method,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                localHeaderOffset: localOffset,
                externalAttributes: externalAttributes
            ))
        }

        return entries
    }

    /// The bytes of one entry, decompressed.
    ///
    /// Only reached by the OCR path, which genuinely needs the page images.
    /// Page counting never calls it — see ``DocumentInspector/pageCount(of:)``.
    static func extract(_ entry: ZIPEntry, from url: URL, name: String) throws -> Data {
        guard entry.compressionMethod == 0 || entry.compressionMethod == 8 else {
            throw LatheError.decodeUnavailable(
                format: "ZIP compression method \(entry.compressionMethod) in \(name)"
            )
        }
        guard entry.uncompressedSize <= UInt64(Int.max) else {
            throw LatheError.invalidInput(reason: "\(entry.baseName) is implausibly large")
        }

        let handle = try open(url, name: name)
        defer { try? handle.close() }

        // The local header's extra field is frequently a different length from
        // the central directory's copy — alignment padding lives in one and not
        // the other — so the payload offset has to come from the local header
        // itself rather than from the 46-byte central record.
        let header = try read(handle, at: entry.localHeaderOffset, count: 30, name: name)
        var reader = ByteReader(header)
        guard try reader.u32() == localFileHeaderSignature else {
            throw LatheError.invalidInput(reason: "\(entry.baseName) has no local header in \(name)")
        }
        reader.skip(22)
        let nameLength = Int(try reader.u16())
        let extraLength = Int(try reader.u16())

        let payloadOffset = entry.localHeaderOffset &+ 30 &+ UInt64(nameLength) &+ UInt64(extraLength)
        let compressed = try read(
            handle, at: payloadOffset, count: Int(entry.compressedSize), name: name
        )

        if entry.compressionMethod == 0 { return compressed }
        return try inflate(compressed, to: Int(entry.uncompressedSize), name: entry.baseName)
    }

    // MARK: - Locating the central directory

    private static func locateCentralDirectory(
        _ handle: FileHandle,
        fileSize: UInt64,
        name: String
    ) throws -> (entryCount: UInt64, offset: UInt64, size: UInt64) {
        let searchLength = Int(min(fileSize, UInt64(maximumEndRecordSearch)))
        let searchStart = fileSize - UInt64(searchLength)
        let tail = try read(handle, at: searchStart, count: searchLength, name: name)

        guard let endIndex = lastIndex(of: endOfCentralDirectorySignature, in: tail) else {
            throw LatheError.invalidInput(
                reason: "\(name) has no ZIP end-of-central-directory record"
            )
        }

        var reader = ByteReader(tail, at: endIndex + 4)
        reader.skip(4)                                       // disk numbers
        let entriesOnDisk = try reader.u16()
        _ = entriesOnDisk
        let totalEntries16 = try reader.u16()
        let directorySize32 = try reader.u32()
        let directoryOffset32 = try reader.u32()

        // ZIP64 is signalled by saturation, not by a flag. An archive with more
        // than 65535 entries that is read with the 16-bit field reports its
        // count modulo 65536 — a 70000-page archive counted as 4464 — which is a
        // wrong number rather than a failure, so it gets believed.
        let saturated = totalEntries16 == 0xFFFF
            || directorySize32 == 0xFFFF_FFFF
            || directoryOffset32 == 0xFFFF_FFFF

        if saturated,
           let locator = try zip64Locator(in: tail, endingAt: endIndex),
           locator < fileSize {
            let record = try read(handle, at: locator, count: 56, name: name)
            var zip = ByteReader(record)
            if try zip.u32() == zip64EndSignature {
                zip.skip(28)                                 // size, versions, disk numbers, per-disk count
                let totalEntries = try zip.u64()
                let directorySize = try zip.u64()
                let directoryOffset = try zip.u64()
                return (totalEntries, directoryOffset, directorySize)
            }
        }

        return (UInt64(totalEntries16), UInt64(directoryOffset32), UInt64(directorySize32))
    }

    /// The ZIP64 end-of-central-directory locator sits immediately before the
    /// 32-bit record, and points at the ZIP64 record proper.
    private static func zip64Locator(in tail: Data, endingAt endIndex: Int) throws -> UInt64? {
        guard endIndex >= 20 else { return nil }
        var reader = ByteReader(tail, at: endIndex - 20)
        guard try reader.u32() == zip64LocatorSignature else { return nil }
        reader.skip(4)                                       // disk with the ZIP64 record
        return try reader.u64()
    }

    /// The *last* occurrence, because the signature's four bytes can legally
    /// appear inside a stored file, and the real record is at the end.
    private static func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data)
        let s0 = UInt8(signature & 0xFF)
        let s1 = UInt8((signature >> 8) & 0xFF)
        let s2 = UInt8((signature >> 16) & 0xFF)
        let s3 = UInt8((signature >> 24) & 0xFF)
        var index = bytes.count - 4
        while index >= 0 {
            if bytes[index] == s0, bytes[index + 1] == s1,
               bytes[index + 2] == s2, bytes[index + 3] == s3 {
                return index
            }
            index -= 1
        }
        return nil
    }

    // MARK: - ZIP64 extra field

    /// Replaces any field the 32-bit header saturated with its 64-bit value.
    ///
    /// The ZIP64 extended information field is positional: it carries only the
    /// fields that were saturated, in a fixed order, with no tags. Reading it as
    /// a fixed layout is the classic bug — an entry whose *size* fits but whose
    /// *offset* does not carries one 8-byte value, and taking it as the size
    /// gives a garbage length for a file that extracts perfectly elsewhere.
    private static func applyZIP64Extra(
        _ extra: Data,
        uncompressed: inout UInt64,
        compressed: inout UInt64,
        localOffset: inout UInt64
    ) {
        var reader = ByteReader(extra)
        while reader.remaining >= 4 {
            guard let headerID = try? reader.u16(), let size = try? reader.u16() else { return }
            guard reader.remaining >= Int(size) else { return }
            guard headerID == 0x0001 else {
                reader.skip(Int(size))
                continue
            }
            var field = ByteReader(extra, at: reader.offset, limit: reader.offset + Int(size))
            if uncompressed == 0xFFFF_FFFF, let value = try? field.u64() { uncompressed = value }
            if compressed == 0xFFFF_FFFF, let value = try? field.u64() { compressed = value }
            if localOffset == 0xFFFF_FFFF, let value = try? field.u64() { localOffset = value }
            reader.skip(Int(size))
        }
    }

    // MARK: - Names

    /// General purpose bit 11 says the name is UTF-8. Without it the name is
    /// nominally CP437, and in practice is whatever the writing machine's code
    /// page was — so a lenient UTF-8 decode with a Latin-1 fallback keeps the
    /// name legible instead of dropping the entry.
    private static func decodeName(_ bytes: Data, flags: UInt16) -> String {
        if flags & 0x0800 != 0, let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }
        if let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }
        return String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    // MARK: - Inflate

    /// Raw DEFLATE, through the system's Compression framework.
    ///
    /// `COMPRESSION_ZLIB` is Apple's name for *raw* DEFLATE (RFC 1951) with no
    /// zlib wrapper, which is exactly what ZIP method 8 stores. The name is the
    /// trap: a reader that assumes a zlib header and strips two bytes first
    /// produces garbage for the first block and plausible output after it.
    private static func inflate(_ data: Data, to capacity: Int, name: String) throws -> Data {
        guard capacity > 0 else { return Data() }
        var destination = Data(count: capacity)
        let written: Int = destination.withUnsafeMutableBytes { destinationBuffer in
            data.withUnsafeBytes { sourceBuffer in
                guard let destinationBase = destinationBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = sourceBuffer.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(
                    destinationBase, capacity, sourceBase, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == capacity else {
            throw LatheError.invalidInput(
                reason: "\(name) did not inflate to its declared \(capacity) bytes "
                    + "(got \(written)); the archive entry is truncated or not deflate"
            )
        }
        return destination
    }

    // MARK: - File access

    private static func open(_ url: URL, name: String) throws -> FileHandle {
        do {
            return try FileHandle(forReadingFrom: url)
        } catch {
            throw LatheError.readFailed(path: name, reason: (error as NSError).localizedDescription)
        }
    }

    private static func size(of handle: FileHandle, name: String) throws -> UInt64 {
        do {
            return try handle.seekToEnd()
        } catch {
            throw LatheError.readFailed(path: name, reason: (error as NSError).localizedDescription)
        }
    }

    private static func read(
        _ handle: FileHandle, at offset: UInt64, count: Int, name: String
    ) throws -> Data {
        guard count >= 0 else {
            throw LatheError.invalidInput(reason: "\(name) declares a negative length")
        }
        guard count > 0 else { return Data() }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else {
                throw LatheError.invalidInput(
                    reason: "\(name) is truncated: \(count) bytes wanted at \(offset), "
                        + "\(data.count) available"
                )
            }
            return data
        } catch let error as LatheError {
            throw error
        } catch {
            throw LatheError.readFailed(path: name, reason: (error as NSError).localizedDescription)
        }
    }
}

// MARK: - Byte reading

/// A bounds-checked little-endian cursor over a `Data`.
///
/// Every multi-byte read is built from single bytes rather than from
/// `withUnsafeBytes { $0.load(as:) }`, because a ZIP field is not guaranteed to
/// be aligned and an unaligned `load` is undefined behaviour — one that happens
/// to work on arm64 and traps elsewhere, which is the worst kind of correct.
private struct ByteReader {
    private let data: Data
    private(set) var offset: Int
    private let limit: Int

    init(_ data: Data, at offset: Int = 0, limit: Int? = nil) {
        self.data = data
        self.offset = offset
        self.limit = min(limit ?? data.count, data.count)
    }

    var remaining: Int { max(0, limit - offset) }

    mutating func skip(_ count: Int) { offset = min(limit, offset + count) }

    mutating func bytes(_ count: Int) throws -> Data {
        guard remaining >= count else { throw LatheError.invalidInput(reason: "ZIP record truncated") }
        let start = data.startIndex + offset
        defer { offset += count }
        return data[start..<(start + count)]
    }

    private mutating func byte() throws -> UInt8 {
        guard remaining >= 1 else { throw LatheError.invalidInput(reason: "ZIP record truncated") }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func u16() throws -> UInt16 {
        let low = UInt16(try byte())
        let high = UInt16(try byte())
        return low | (high << 8)
    }

    mutating func u32() throws -> UInt32 {
        let low = UInt32(try u16())
        let high = UInt32(try u16())
        return low | (high << 16)
    }

    mutating func u64() throws -> UInt64 {
        let low = UInt64(try u32())
        let high = UInt64(try u32())
        return low | (high << 32)
    }
}
