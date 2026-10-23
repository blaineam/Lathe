import Foundation
import LatheCore

/// Rewrites the `moov` atom of an MP4-family file where the file is, leaving
/// every sample where it was.
///
/// ## The arithmetic that makes this worth having
///
/// A tag change touches a few kilobytes — plus the cover art — inside one atom,
/// `moov/udta/meta/ilst`. The passthrough export reads every sample of the film
/// to write every sample of a new film, which on a mounted remote volume is
/// minutes for a change that is a few megabytes of writing. The samples never
/// needed to move: `mdat` is addressed by absolute offsets from the sample
/// tables, and as long as it stays where it is those offsets stay right.
///
/// ## What is rebuilt and what is copied
///
/// The new `moov` is the old one with `udta/meta/ilst` replaced: the tags
/// ``MediaMetadata`` names are written fresh, exactly as ``MetadataItemBuilder``
/// would hand them to AVFoundation, and every `ilst` item it has no name for
/// — `©too`, `----` freeform items, sort names — is copied byte for byte, so a
/// read-modify-write keeps them. Every track, every sample table, every edit
/// list is copied unread. A tag the file keeps *outside* `ilst` that a reader
/// would surface as one of the same fields — the 3GPP `titl`/`perf`/`thmb`
/// family and QuickTime's `©nam` user-data atoms — is dropped, because a write
/// replaces, and a cleared title that came back from a second copy would not
/// have been cleared. That is what the export does too.
///
/// ## Crash safety
///
/// No step leaves the file without one complete, correctly labelled `moov`:
///
/// 1. The new `moov` is appended after the last atom. Until step 2 it is a
///    trailing atom nothing refers to; interrupted, it is trailing junk, which
///    players ignore and the next write cuts off.
/// 2. The old `moov`'s header is relabelled `free` — eight bytes, one write.
///    The file is now valid with the new `moov` at the end.
/// 3. Where a run of free space at least as big as the new `moov` exists —
///    the old slot, typically — the body is written into it under the `free`
///    label, then the eight-byte header is relabelled `moov`. For a moment the
///    file carries two identical `moov`s; players take the first.
/// 4. The trailing copy is cut off with one truncate.
///
/// Each step is forced to disk before the next. A file whose `moov` led
/// stays led when the new one fits, which keeps it streamable; when it does
/// not fit, the old slot becomes a `free` hole, the `moov` moves to the end,
/// and a later edit that fits the hole moves it back.
enum MP4InPlace {

    // MARK: - Inspection

    /// What a file looks like, read once, before anything is decided.
    struct Inspection {
        var url: URL
        var length: UInt64
        /// The top-level table, without the trailing bytes `trimOffset` names.
        var boxes: [ISOBox]
        /// Where an interrupted earlier write left a partial atom or a
        /// duplicate `moov`; cut off before anything else happens.
        var trimOffset: UInt64?
        var moov: ISOBox
        /// `moov`'s payload — everything after its header.
        var moovPayload: Data
        var moovChildren: [ISOBox]
        /// The `ftyp` atom, bytes and all, for the stub the result is read
        /// back from before it is committed.
        var ftyp: Data?

        /// The bytes of one child of `moov`.
        func bytes(of box: ISOBox) -> Data {
            let start = Int(box.offset - moov.payloadOffset)
            return moovPayload.subdata(in: start..<start + Int(box.size))
        }
    }

    /// Atom types whose presence means the file is fragmented, and its
    /// samples are addressed by something other than `moov`.
    static let fragmentMarkers: Set<String> = ["moof", "mfra", "sidx", "styp", "ssix"]

    /// The most `moov` this will hold in memory. Ten megabytes is a film with
    /// a large poster; a quarter of a gigabyte is not a metadata atom.
    static let maximumMoovBytes: UInt64 = 256 * 1024 * 1024

    static func inspect(_ url: URL) throws -> Inspection {
        try MetaFiles.requireReadableFile(at: url)
        let store = try MetadataStore.detect(at: url)
        guard store == .iTunesAtoms else {
            throw LatheError.invalidInput(
                reason: "\(url.lastPathComponent) keeps its tags as \(store), not in a moov atom"
            )
        }

        let file = try ISOFileReader(url: url)
        var (boxes, trim) = try ISOBMFF.topLevel(of: file)

        // A second moov at the very end is the copy an interrupted write
        // appended and had not yet cut off: the leading one is complete and is
        // the one every player used, so the trailing one goes.
        let moovCount = boxes.filter { $0.type == "moov" }.count
        if moovCount == 2, let last = boxes.last, last.type == "moov" {
            trim = last.offset
            boxes.removeLast()
        }

        let moovs = boxes.filter { $0.type == "moov" }
        guard let moov = moovs.first else {
            throw LatheError.invalidInput(reason: "\(url.lastPathComponent) has no moov atom")
        }
        guard moovs.count == 1 else {
            throw LatheError.invalidInput(
                reason: "\(url.lastPathComponent) has \(moovs.count) moov atoms"
            )
        }
        if let fragment = boxes.first(where: { fragmentMarkers.contains($0.type) }) {
            throw LatheError.invalidInput(
                reason: "\(url.lastPathComponent) is fragmented (it has a \(fragment.type) atom)"
            )
        }
        if let open = boxes.first(where: { $0.extendsToEnd }) {
            throw LatheError.invalidInput(
                reason: "\(url.lastPathComponent)'s \(open.type) atom extends to the end of the "
                    + "file, so nothing can be appended after it"
            )
        }
        guard moov.payloadSize <= maximumMoovBytes else {
            throw LatheError.invalidInput(
                reason: "\(url.lastPathComponent)'s moov atom is \(moov.size) bytes, too large to rewrite in memory"
            )
        }

        let payload = try file.readExactly(at: moov.payloadOffset, count: Int(moov.payloadSize))
        let children = try ISOBMFF.children(of: payload, base: moov.payloadOffset, in: "moov")
        if children.contains(where: { $0.type == "mvex" }) {
            throw LatheError.invalidInput(
                reason: "\(url.lastPathComponent) is fragmented (its moov has an mvex atom)"
            )
        }

        var ftyp: Data?
        if let first = boxes.first, first.type == "ftyp" {
            ftyp = try file.readExactly(at: first.offset, count: Int(first.size))
        }

        let inspection = Inspection(
            url: url, length: file.length, boxes: boxes, trimOffset: trim,
            moov: moov, moovPayload: payload, moovChildren: children, ftyp: ftyp
        )
        // Building is the rest of the proof: a udta or meta this cannot take
        // apart is one it must not put back together.
        _ = try buildMoov(inspection, metadata: MediaMetadata())
        return inspection
    }

    // MARK: - Building the new moov

    /// User-data atoms a reader surfaces as the same fields `ilst` carries.
    /// Dropped on a write for the reason the type's note gives.
    static let competingUserData: Set<String> = [
        // 3GPP asset information.
        "titl", "dscp", "perf", "auth", "gnre", "cprt", "albm", "yrrc", "rtng", "clsf", "kywd", "loci", "thmb",
    ]

    /// Keys in `moov/meta` — QuickTime's own key/value metadata — that
    /// AVFoundation gives a common key, and so that ``MetadataReader`` would
    /// read into the same fields as the `ilst` tags.
    static let competingQuickTimeKeys: Set<String> = [
        "com.apple.quicktime.title", "com.apple.quicktime.artist", "com.apple.quicktime.author",
        "com.apple.quicktime.description", "com.apple.quicktime.comment", "com.apple.quicktime.copyright",
        "com.apple.quicktime.creationdate", "com.apple.quicktime.album", "com.apple.quicktime.artwork",
        "com.apple.quicktime.genre", "com.apple.quicktime.keywords",
    ]

    /// The complete `moov` atom carrying `metadata`.
    ///
    /// - Parameter padding: extra bytes to make the atom longer by, for a
    ///   slot that is bigger than the atom by less than a `free` atom's header.
    ///   They go on the end of the `hdlr` name, which is a string of any length
    ///   that nothing displays.
    static func buildMoov(_ inspection: Inspection, metadata: MediaMetadata, padding: Int = 0, now: Date = Date()) throws -> Data {
        var out = Data()
        var udtaDone = false
        for child in inspection.moovChildren {
            let raw = inspection.bytes(of: child)
            switch child.type {
            case "udta":
                out.append(try rebuildUserData(raw, box: child, metadata: metadata, padding: padding))
                udtaDone = true
            case "mvhd":
                out.append(stampModificationTime(raw, now: now))
            case "meta":
                if let kept = try rebuildQuickTimeMeta(raw, box: child) { out.append(kept) }
            default:
                out.append(raw)
            }
        }
        if !udtaDone {
            out.append(try rebuildUserData(nil, box: nil, metadata: metadata, padding: padding))
        }
        return ISOBMFF.header(type: "moov", size: UInt64(out.count) + 8) + out
    }

    /// `udta` with a new `meta`, every other child it had, and none of the
    /// atoms that would compete with the tags just written.
    private static func rebuildUserData(_ raw: Data?, box: ISOBox?, metadata: MediaMetadata, padding: Int) throws -> Data {
        var kept: [Data] = []
        var oldMeta: (bytes: Data, box: ISOBox)?
        var metaPosition: Int?
        if let raw, let box {
            let payload = raw.subdata(in: Int(box.headerSize)..<raw.count)
            let children = try ISOBMFF.children(of: payload, base: box.payloadOffset, in: "udta")
            for child in children {
                let start = Int(child.offset - box.payloadOffset)
                let bytes = payload.subdata(in: start..<start + Int(child.size))
                if child.type == "meta" {
                    guard oldMeta == nil else {
                        throw LatheError.invalidInput(reason: "udta holds two meta atoms")
                    }
                    oldMeta = (bytes, child)
                    metaPosition = kept.count
                    continue
                }
                if competingUserData.contains(child.type) || child.type.unicodeScalars.first == "\u{A9}" {
                    continue
                }
                kept.append(bytes)
            }
        }
        let meta = try rebuildTagMeta(oldMeta, metadata: metadata, padding: padding)
        kept.insert(meta, at: metaPosition ?? kept.count)
        let payload = kept.reduce(into: Data()) { $0.append($1) }
        return ISOBMFF.box("udta", payload)
    }

    /// The `ilst` atom types this module writes itself, and so replaces. The
    /// numeric genre is included because it is the same field as `©gen`.
    static let managedItemTypes: Set<String> = [
        "\u{A9}nam", "desc", "ldes", "\u{A9}ART", "\u{A9}gen", "gnre", "\u{A9}cmt", "cprt", "\u{A9}day",
        "stik", "covr", "tvsh", "tvsn", "tves", "tven", "tvnn", "\u{A9}alb", "aART", "\u{A9}wrt",
        "trkn", "disk", "cpil",
    ]

    /// `udta/meta`: a full box holding an `mdir` handler and the `ilst`.
    private static func rebuildTagMeta(_ old: (bytes: Data, box: ISOBox)?, metadata: MediaMetadata, padding: Int) throws -> Data {
        var preserved: [Data] = []
        var otherChildren: [Data] = []
        if let old {
            let (children, payload, base) = try metaChildren(old.bytes, box: old.box)
            for child in children {
                let start = Int(child.offset - base)
                let bytes = payload.subdata(in: start..<start + Int(child.size))
                switch child.type {
                case "hdlr":
                    guard child.size >= 24 else {
                        throw LatheError.invalidInput(reason: "udta/meta has a truncated hdlr atom")
                    }
                    let handler = ISOBMFF.fourCC(bytes, at: Int(child.headerSize) + 8)
                    guard handler == "mdir" else {
                        throw LatheError.invalidInput(
                            reason: "udta/meta is handled by \(handler), not the iTunes mdir this rewrites"
                        )
                    }
                case "keys":
                    throw LatheError.invalidInput(reason: "udta/meta uses key/value metadata rather than iTunes atoms")
                case "ilst":
                    let items = try ISOBMFF.children(
                        of: bytes.subdata(in: Int(child.headerSize)..<bytes.count), base: child.payloadOffset, in: "ilst"
                    )
                    for item in items where !managedItemTypes.contains(item.type) {
                        let itemStart = Int(item.offset - child.offset)
                        preserved.append(bytes.subdata(in: itemStart..<itemStart + Int(item.size)))
                    }
                case "free", "skip":
                    continue
                default:
                    otherChildren.append(bytes)
                }
            }
        }

        var ilst = Data()
        for item in ILSTItems.items(for: metadata) { ilst.append(item) }
        for item in preserved { ilst.append(item) }

        var meta = Data([0, 0, 0, 0])
        meta.append(handler(padding: padding))
        meta.append(ISOBMFF.box("ilst", ilst))
        for other in otherChildren { meta.append(other) }
        return ISOBMFF.box("meta", meta)
    }

    /// The `mdir`/`appl` handler every iTunes-tagged file carries.
    private static func handler(padding: Int) -> Data {
        var payload = Data(repeating: 0, count: 8)       // version/flags, pre_defined
        payload.append(ISOBMFF.fourCC("mdir"))
        payload.append(ISOBMFF.fourCC("appl"))
        payload.append(Data(repeating: 0, count: 8))     // reserved
        payload.append(Data(repeating: 0, count: 1 + max(0, padding)))  // name, NUL-terminated
        return ISOBMFF.box("hdlr", payload)
    }

    /// The children of a `meta` atom, which is a full box in an MP4 and a
    /// plain box in a QuickTime file. The first child tells which: it begins
    /// either four bytes in or eight.
    private static func metaChildren(_ bytes: Data, box: ISOBox) throws -> (children: [ISOBox], payload: Data, base: UInt64) {
        let header = Int(box.headerSize)
        guard bytes.count >= header + 12 else {
            throw LatheError.invalidInput(reason: "a meta atom is too short to hold anything")
        }
        let plainType = ISOBMFF.fourCC(bytes, at: header + 4)
        let fullType = ISOBMFF.fourCC(bytes, at: header + 8)
        let skip: Int
        if plainType == "hdlr" {
            skip = 0
        } else if fullType == "hdlr" {
            skip = 4
        } else {
            // Neither: a full box whose first child is not the handler.
            skip = 4
        }
        let payload = bytes.subdata(in: header + skip..<bytes.count)
        let base = box.payloadOffset + UInt64(skip)
        return (try ISOBMFF.children(of: payload, base: base, in: "meta"), payload, base)
    }

    /// `moov/meta` — QuickTime's keyed metadata — with the keys that would
    /// compete with the tags removed, and renumbered, since each `ilst` item is
    /// addressed by its key's 1-based index.
    ///
    /// - Returns: `nil` when nothing is left worth keeping.
    private static func rebuildQuickTimeMeta(_ raw: Data, box: ISOBox) throws -> Data? {
        let (children, payload, base) = try metaChildren(raw, box: box)
        let isFullBox = base != box.payloadOffset
        guard let keysBox = children.first(where: { $0.type == "keys" }) else {
            // An iTunes-style list directly under moov would compete with the
            // one in udta; anything else here is not metadata a reader shows.
            if let hdlr = children.first(where: { $0.type == "hdlr" }), hdlr.size >= 24 {
                let start = Int(hdlr.offset - base)
                let handler = ISOBMFF.fourCC(payload, at: start + Int(hdlr.headerSize) + 8)
                if handler == "mdir" {
                    throw LatheError.invalidInput(reason: "moov/meta holds a second iTunes tag list")
                }
            }
            return raw
        }

        // keys: version/flags, entry count, then [size][namespace][name] each.
        let keysStart = Int(keysBox.offset - base)
        let keysPayload = payload.subdata(in: keysStart + Int(keysBox.headerSize)..<keysStart + Int(keysBox.size))
        guard keysPayload.count >= 8 else {
            throw LatheError.invalidInput(reason: "moov/meta has a truncated keys atom")
        }
        let count = Int(ISOBMFF.uint32(keysPayload, at: 4))
        var entries: [(namespace: String, name: String, raw: Data)] = []
        var cursor = 8
        for _ in 0..<count {
            guard keysPayload.count - cursor >= 8 else {
                throw LatheError.invalidInput(reason: "moov/meta's keys atom ends early")
            }
            let size = Int(ISOBMFF.uint32(keysPayload, at: cursor))
            guard size >= 8, cursor + size <= keysPayload.count else {
                throw LatheError.invalidInput(reason: "moov/meta holds a key with an impossible size")
            }
            let namespace = ISOBMFF.fourCC(keysPayload, at: cursor + 4)
            let name = String(decoding: keysPayload.subdata(in: cursor + 8..<cursor + size), as: UTF8.self)
            entries.append((namespace, name, keysPayload.subdata(in: cursor..<cursor + size)))
            cursor += size
        }

        let competing = Set(entries.indices.filter {
            entries[$0].namespace == "mdta" && competingQuickTimeKeys.contains(entries[$0].name)
        })
        guard !competing.isEmpty else { return raw }

        // Renumber: old 1-based index → new 1-based index, for the survivors.
        var renumbered: [Int: Int] = [:]
        var next = 1
        for index in entries.indices where !competing.contains(index) {
            renumbered[index + 1] = next
            next += 1
        }
        guard next > 1 else { return nil }

        var newKeys = Data(keysPayload.prefix(4))
        newKeys.append(contentsOf: ISOBMFF.bytes(UInt32(next - 1)))
        for index in entries.indices where !competing.contains(index) { newKeys.append(entries[index].raw) }

        var out = Data()
        if isFullBox { out.append(contentsOf: [0, 0, 0, 0]) }
        for child in children {
            let start = Int(child.offset - base)
            let bytes = payload.subdata(in: start..<start + Int(child.size))
            switch child.type {
            case "keys":
                out.append(ISOBMFF.box("keys", newKeys))
            case "ilst":
                let items = try ISOBMFF.children(
                    of: bytes.subdata(in: Int(child.headerSize)..<bytes.count), base: child.payloadOffset, in: "meta/ilst"
                )
                var list = Data()
                for item in items {
                    let itemStart = Int(item.offset - child.offset)
                    let itemBytes = bytes.subdata(in: itemStart..<itemStart + Int(item.size))
                    let oldIndex = Int(ISOBMFF.uint32(itemBytes, at: 4))
                    guard let newIndex = renumbered[oldIndex] else {
                        // Either a competing key's value, or an item with no
                        // key at all; neither is kept.
                        continue
                    }
                    var renamed = itemBytes
                    renamed.replaceSubrange(4..<8, with: ISOBMFF.bytes(UInt32(newIndex)))
                    list.append(renamed)
                }
                out.append(ISOBMFF.box("ilst", list))
            default:
                out.append(bytes)
            }
        }
        return ISOBMFF.box("meta", out)
    }

    /// Seconds between the QuickTime epoch, 1904, and the Unix one.
    static let macEpochOffset: TimeInterval = 2_082_844_800

    /// `mvhd` with its modification time set to `now`, which is what a tag
    /// write is.
    static func stampModificationTime(_ raw: Data, now: Date) -> Data {
        guard raw.count >= 8 + 4 else { return raw }
        let header = 8
        let version = raw[raw.startIndex + header]
        let stamp = UInt64(max(0, now.timeIntervalSince1970 + macEpochOffset))
        var out = raw
        if version == 1, raw.count >= header + 4 + 16 {
            out.replaceSubrange(header + 12..<header + 20, with: ISOBMFF.bytes(stamp))
        } else if version == 0, raw.count >= header + 4 + 8 {
            out.replaceSubrange(header + 8..<header + 12, with: ISOBMFF.bytes(UInt32(min(stamp, UInt64(UInt32.max)))))
        }
        return out
    }

    // MARK: - Committing

    /// The points at which a write has forced its bytes to disk — the places a
    /// test interrupts it.
    enum Step: Sendable, Equatable, CaseIterable {
        case trimmed
        case appendedCopy
        case retiredOldMoov
        /// Only when the old `moov` was last and the new one is bigger: a
        /// second copy goes after the first, so the first can be retired and
        /// its space joined to the old slot. Three writes of the atom, and a
        /// file that ends exactly where it should.
        case appendedSecondCopy
        case retiredFirstCopy
        /// Only when the slot is several `free` atoms: the first one's header
        /// is widened to cover them all, so that the body written next lands
        /// inside one atom rather than over the headers of the others.
        case mergedSlot
        case wroteBodyIntoSlot
        case activatedSlot
        case truncatedCopy
    }

    /// Test seams. `afterStep` runs after every forced write; throwing from it
    /// abandons the write there, which is what a crash does.
    struct Hooks {
        var afterStep: ((Step) throws -> Void)?
        init(afterStep: ((Step) throws -> Void)? = nil) { self.afterStep = afterStep }
    }

    struct Report: Sendable, Equatable {
        /// Every byte handed to the file, headers and the trailing copy included.
        var bytesWritten: UInt64
        /// Where the active `moov` ended up.
        var moovOffset: UInt64
        var fileLength: UInt64
        /// Whether the new `moov` was placed into existing free space rather
        /// than left at the end of the file.
        var compacted: Bool
        var steps: [Step]
    }

    /// Writes `moov` into the file described by `inspection`.
    ///
    /// - Parameter rebuild: makes the atom again `padding` bytes longer, for
    ///   a slot that is bigger than it by less than a `free` header.
    static func commit(
        _ inspection: Inspection, moov: Data, rebuild: (_ padding: Int) throws -> Data, hooks: Hooks = Hooks()
    ) throws -> Report {
        let file = try ISOFileWriter(url: inspection.url)
        guard file.length == inspection.length else {
            throw LatheError.writeFailed(
                path: inspection.url.lastPathComponent,
                reason: "the file changed length between being read and being written"
            )
        }
        var steps: [Step] = []
        func step(_ step: Step) throws {
            try file.sync()
            steps.append(step)
            try hooks.afterStep?(step)
        }

        if let trim = inspection.trimOffset {
            try file.truncate(at: trim)
            try step(.trimmed)
        }
        var boxes = inspection.boxes
        var end = boxes.last?.end ?? 0

        // 1. The copy at the end.
        try file.write(moov, at: end)
        try step(.appendedCopy)

        // 2. Retire the old one. Eight bytes: the size stays, the label changes.
        let old = inspection.moov
        let retired = old.headerSize == 16
            ? Data(ISOBMFF.bytes(UInt32(1))) + ISOBMFF.fourCC("free")
            : Data(ISOBMFF.bytes(UInt32(old.size))) + ISOBMFF.fourCC("free")
        try file.write(retired, at: old.offset)
        try step(.retiredOldMoov)
        if let index = boxes.firstIndex(where: { $0.offset == old.offset }) {
            boxes[index].type = "free"
        }

        // 3. Into free space, when there is enough.
        let need = UInt64(moov.count)
        var runs = freeRuns(in: boxes)
        if !runs.contains(where: { $0.size >= need }),
           let last = runs.last, last.offset + last.size == end {
            // The old moov was at the end and the new one is bigger. The
            // trailing copy sits right after the old slot, so the slot cannot
            // grow over it — unless a further copy takes over first.
            try file.write(moov, at: end + need)
            try step(.appendedSecondCopy)
            try file.write(Data(ISOBMFF.bytes(UInt32(need))) + ISOBMFF.fourCC("free"), at: end)
            try step(.retiredFirstCopy)
            boxes.append(ISOBox(type: "free", offset: end, headerSize: 8, size: need))
            end += need
            runs = freeRuns(in: boxes)
        }
        guard let run = runs.first(where: { $0.size >= need }) else {
            return Report(
                bytesWritten: file.bytesWritten, moovOffset: end,
                fileLength: end + need, compacted: false, steps: steps
            )
        }
        if run.boxes > 1 {
            try file.write(ISOBMFF.header(type: "free", size: run.size), at: run.offset)
            try step(.mergedSlot)
        }
        let gap = run.size - need
        var body = moov
        if gap > 0, gap < 8 {
            body = try rebuild(Int(gap))
            guard UInt64(body.count) == run.size else {
                throw LatheError.writeFailed(
                    path: inspection.url.lastPathComponent,
                    reason: "padding the moov by \(gap) bytes made it \(body.count) bytes, not \(run.size)"
                )
            }
        }
        try file.write(body.subdata(in: 8..<body.count), at: run.offset + 8)
        if gap >= 8 {
            try file.write(ISOBMFF.header(type: "free", size: gap), at: run.offset + UInt64(body.count))
        }
        try step(.wroteBodyIntoSlot)

        try file.write(body.prefix(8), at: run.offset)
        try step(.activatedSlot)

        // 4. Cut the trailing copy off — and the padding with it when the slot
        // ran right up to it, and any free space that did.
        var cut = end
        if run.offset + run.size == end {
            cut = run.offset + UInt64(body.count)
        } else if let trailing = runs.last, trailing.offset + trailing.size == end, trailing.offset > run.end {
            cut = trailing.offset
        }
        try file.truncate(at: cut)
        try step(.truncatedCopy)

        return Report(
            bytesWritten: file.bytesWritten, moovOffset: run.offset,
            fileLength: cut, compacted: true, steps: steps
        )
    }

    /// A stretch of contiguous `free` and `skip` atoms.
    struct FreeRun: Equatable {
        var offset: UInt64
        var size: UInt64
        /// How many atoms make it up.
        var boxes: Int
        var end: UInt64 { offset + size }
    }

    /// The runs of free space, in file order.
    static func freeRuns(in boxes: [ISOBox]) -> [FreeRun] {
        var runs: [FreeRun] = []
        for box in boxes {
            guard box.type == "free" || box.type == "skip" else { continue }
            if let last = runs.last, last.end == box.offset {
                runs[runs.count - 1].size += box.size
                runs[runs.count - 1].boxes += 1
            } else {
                runs.append(FreeRun(offset: box.offset, size: box.size, boxes: 1))
            }
        }
        return runs
    }
}

// MARK: - The ilst items

/// ``MediaMetadata`` as iTunes `ilst` atoms — the same set, in the same
/// spellings, that ``MetadataItemBuilder`` gives AVFoundation, so a file
/// written either way reads the same.
enum ILSTItems {

    /// Well-known `data` atom type indicators.
    enum DataType: UInt32 {
        case binary = 0
        case utf8 = 1
        case jpeg = 13
        case png = 14
        case signedInteger = 21
    }

    static func items(for metadata: MediaMetadata) -> [Data] {
        var items: [Data] = []

        func text(_ type: String, _ value: String?) {
            guard let value else { return }
            items.append(item(type, [data(.utf8, Data(value.utf8))]))
        }
        func integer(_ type: String, _ value: Int?, bytes width: Int) {
            guard let value else { return }
            var payload = Data()
            for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
                payload.append(UInt8(truncatingIfNeeded: value >> shift))
            }
            items.append(item(type, [data(.signedInteger, payload)]))
        }

        text("\u{A9}nam", metadata.title)
        text("desc", metadata.summary)
        text("ldes", metadata.longDescription)
        text("\u{A9}ART", metadata.creators.isEmpty ? nil : metadata.creators.joined(separator: ", "))
        text("\u{A9}gen", metadata.genre)
        text("\u{A9}cmt", metadata.comment)
        text("cprt", metadata.copyrightNotice)
        text("\u{A9}day", metadata.date.map { MetadataDates.format($0) })
        integer("stik", metadata.kind?.rawValue, bytes: 1)

        if let show = metadata.show {
            text("tvsh", show.seriesName)
            integer("tvsn", show.seasonNumber, bytes: 4)
            integer("tves", show.episodeNumber, bytes: 4)
            text("tven", show.episodeID)
            text("tvnn", show.network)
        }

        if let track = metadata.track {
            text("\u{A9}alb", track.albumName)
            text("aART", track.albumArtist)
            text("\u{A9}wrt", track.composer)
            integer("cpil", track.isCompilation.map { $0 ? 1 : 0 }, bytes: 1)
            if let number = track.trackNumber {
                items.append(item("trkn", [data(.binary, packedIndex(number, of: track.trackCount))]))
            }
            if let number = track.discNumber {
                items.append(item("disk", [data(.binary, packedIndex(number, of: track.discCount))]))
            }
        }

        if !metadata.artwork.isEmpty {
            // One covr atom with one data child per image, which is how iTunes
            // stores several and how AVFoundation reads them back as items.
            items.append(item("covr", metadata.artwork.map {
                data($0.format == .png ? .png : .jpeg, $0.data)
            }))
        }

        return items
    }

    static func item(_ type: String, _ children: [Data]) -> Data {
        ISOBMFF.box(type, children.reduce(into: Data()) { $0.append($1) })
    }

    /// A `data` atom: type indicator, locale (zero), payload.
    static func data(_ type: DataType, _ payload: Data) -> Data {
        var body = Data(ISOBMFF.bytes(type.rawValue))
        body.append(contentsOf: [0, 0, 0, 0])
        body.append(payload)
        return ISOBMFF.box("data", body)
    }

    /// The 8-byte record `trkn` and `disk` hold; see ``MetadataItemBuilder``.
    static func packedIndex(_ index: Int, of total: Int?) -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[2] = UInt8((index >> 8) & 0xFF)
        bytes[3] = UInt8(index & 0xFF)
        if let total {
            bytes[4] = UInt8((total >> 8) & 0xFF)
            bytes[5] = UInt8(total & 0xFF)
        }
        return Data(bytes)
    }
}

// MARK: - Positioned writes

/// Positioned writes to one open file, with every write counted and every
/// sync real.
final class ISOFileWriter {
    private let handle: FileHandle
    private(set) var length: UInt64
    private(set) var bytesWritten: UInt64 = 0
    let name: String

    init(url: URL) throws {
        name = url.lastPathComponent
        do {
            handle = try FileHandle(forUpdating: url)
            length = try handle.seekToEnd()
        } catch {
            throw LatheError.writeFailed(
                path: url.lastPathComponent, reason: (error as NSError).localizedDescription
            )
        }
    }

    deinit { try? handle.close() }

    func write(_ data: Data, at offset: UInt64) throws {
        do {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
        } catch {
            throw LatheError.writeFailed(path: name, reason: (error as NSError).localizedDescription)
        }
        bytesWritten += UInt64(data.count)
        length = max(length, offset + UInt64(data.count))
    }

    func truncate(at offset: UInt64) throws {
        do {
            try handle.truncate(atOffset: offset)
        } catch {
            throw LatheError.writeFailed(path: name, reason: (error as NSError).localizedDescription)
        }
        length = offset
    }

    /// Forces everything written so far onto the disk.
    ///
    /// `F_FULLFSYNC` first, which asks the drive to flush its own cache and is
    /// the only call that means "on the platter"; then `fsync`, for a file
    /// system that does not offer the first. A volume that supports neither —
    /// some network mounts — is not a reason to refuse the write, so those
    /// particular refusals are ignored and any other failure is reported.
    func sync() throws {
        let fd = handle.fileDescriptor
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        if fsync(fd) == 0 { return }
        switch errno {
        case ENOTSUP, EINVAL, ENOTTY, EOPNOTSUPP:
            return
        default:
            throw LatheError.writeFailed(path: name, reason: "fsync: \(String(cString: strerror(errno)))")
        }
    }
}
