import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import LatheCore
import LatheFixtures
import Testing
import UniformTypeIdentifiers

@testable import LatheMeta

/// Rewriting only the `moov` atom: every placement the layout can call for,
/// every point an interruption can land on, and the proof that the samples
/// were never touched.
@Suite("In-place metadata writes", .serialized)
struct InPlaceWriteTests {

    private let reader = MetadataReader()
    private let writer = MetadataWriter()

    // MARK: - Placement

    /// A fast-start file whose new moov is the same size, or within a few
    /// bytes of it, stays exactly where it was: same offset, same file length.
    @Test("a same-size edit on a fast-start file leaves the moov where it was")
    func fastStartSameSizeStaysPut() async throws {
        let file = try await fastStartM4A("inplace-same")
        let before = try table(of: file)
        let moovBefore = try #require(before.first { $0.type == "moov" })
        #expect(before.map(\.type) == ["ftyp", "moov", "mdat"])
        let mdatBefore = try bytes(of: "mdat", in: file)

        let (result, report) = try await writer.writeInPlace(
            try await edited(file) { $0.title = "X" }, at: file, fallback: .refuse)
        let report0 = try #require(report)
        #expect(result.wroteInPlace)
        #expect(report0.compacted)
        #expect(report0.moovOffset == moovBefore.offset)
        #expect(try fileSize(file) == result.inputByteCount, "the file changed length")
        let after = try table(of: file)
        #expect(after.map(\.type) == ["ftyp", "moov", "mdat"])
        #expect(try bytes(of: "mdat", in: file) == mdatBefore, "the samples were touched")
        #expect(try await reader.read(file).title == "X")
        try await expectReadable(file)
        // Twice the moov, plus a free header at most, plus two 8-byte labels.
        let moovAfter = try #require(after.first { $0.type == "moov" })
        #expect(report0.bytesWritten <= 2 * moovAfter.size + 24, "wrote \(report0.bytesWritten) for a \(moovAfter.size)-byte moov")
    }

    /// A smaller moov is padded with a `free` atom so `mdat` stays put.
    @Test("a smaller edit on a fast-start file is padded with a free atom")
    func fastStartSmallerIsPadded() async throws {
        let file = try await fastStartM4A("inplace-smaller")
        let lengthBefore = try fileSize(file)
        let moovBefore = try #require(try table(of: file).first { $0.type == "moov" })

        let (_, report) = try await writer.writeInPlace(
            try await edited(file) { $0.artwork = [] }, at: file, fallback: .refuse)
        let report0 = try #require(report)
        #expect(report0.compacted)
        #expect(report0.moovOffset == moovBefore.offset)
        #expect(try fileSize(file) == lengthBefore)
        let after = try table(of: file)
        #expect(after.map(\.type) == ["ftyp", "moov", "free", "mdat"], "\(after)")
        let moovAfter = try #require(after.first { $0.type == "moov" })
        let free = try #require(after.first { $0.type == "free" })
        #expect(moovAfter.size + free.size == moovBefore.size)
        #expect(try await reader.read(file).artwork.isEmpty)
        try await expectReadable(file)
    }

    /// A moov at the end that grows takes the file's end with it, and leaves
    /// no hole behind: the file ends exactly after the new moov.
    @Test("a larger edit on a moov-last file appends and leaves no hole")
    func moovLastLargerAppends() async throws {
        let file = try await m4a("inplace-append")
        let before = try table(of: file)
        #expect(before.map(\.type) == ["ftyp", "mdat", "moov"])
        let moovBefore = try #require(before.first { $0.type == "moov" })
        let mdatBefore = try bytes(of: "mdat", in: file)
        let cover = try #require(Artwork(sniffing: try Self.noisePNG(side: 256)))

        let (result, report) = try await writer.writeInPlace(
            try await edited(file) { $0.artwork = [cover] }, at: file, fallback: .refuse)
        let report0 = try #require(report)
        #expect(report0.compacted)
        #expect(report0.steps.contains(.appendedSecondCopy))
        #expect(report0.moovOffset == moovBefore.offset)
        let after = try table(of: file)
        #expect(after.map(\.type) == ["ftyp", "mdat", "moov"], "\(after)")
        let moovAfter = try #require(after.first { $0.type == "moov" })
        // The old cover, a couple of hundred bytes, went; the new one came.
        #expect(moovAfter.size > moovBefore.size + UInt64(cover.data.count) - 1024)
        #expect(try fileSize(file) == moovAfter.end, "the file does not end at the moov")
        #expect(result.outputByteCount == moovAfter.end)
        #expect(try bytes(of: "mdat", in: file) == mdatBefore)
        #expect(try await reader.read(file).artwork.first?.data == cover.data)
        try await expectReadable(file)
    }

    /// A moov at the end that shrinks is written over the old one and the
    /// file is cut short.
    @Test("a smaller edit on a moov-last file truncates")
    func moovLastSmallerTruncates() async throws {
        let file = try await m4a("inplace-shrink")
        let moovBefore = try #require(try table(of: file).first { $0.type == "moov" })

        let (_, report) = try await writer.writeInPlace(
            try await edited(file) { $0.artwork = []; $0.track = nil }, at: file, fallback: .refuse)
        let report0 = try #require(report)
        #expect(report0.compacted)
        #expect(report0.moovOffset == moovBefore.offset)
        let after = try table(of: file)
        #expect(after.map(\.type) == ["ftyp", "mdat", "moov"], "\(after)")
        let moovAfter = try #require(after.first { $0.type == "moov" })
        #expect(moovAfter.size < moovBefore.size)
        #expect(try fileSize(file) == moovAfter.end)
        try await expectReadable(file)
    }

    /// The one case the samples' position forbids: a fast-start moov that no
    /// longer fits in front of `mdat`. The old slot becomes `free`, the new
    /// moov goes to the end — and comes back to the front as soon as an edit
    /// fits there again.
    @Test("a larger edit on a fast-start file moves the moov to the end, and a smaller one brings it back")
    func fastStartLargerMovesToEndAndBack() async throws {
        let file = try await fastStartM4A("inplace-grow")
        let lengthBefore = try fileSize(file)
        let moovBefore = try #require(try table(of: file).first { $0.type == "moov" })
        let mdatBefore = try bytes(of: "mdat", in: file)
        let cover = try #require(Artwork(sniffing: try Self.noisePNG(side: 256)))

        let (_, grown) = try await writer.writeInPlace(
            try await edited(file) { $0.artwork = [cover] }, at: file, fallback: .refuse)
        let grown0 = try #require(grown)
        #expect(!grown0.compacted)
        let afterGrowth = try table(of: file)
        #expect(afterGrowth.map(\.type) == ["ftyp", "free", "mdat", "moov"], "\(afterGrowth)")
        #expect(afterGrowth[1].offset == moovBefore.offset && afterGrowth[1].size == moovBefore.size)
        #expect(grown0.moovOffset == afterGrowth[3].offset)
        #expect(try bytes(of: "mdat", in: file) == mdatBefore)
        #expect(try await reader.read(file).artwork.first?.data == cover.data)
        try await expectReadable(file)

        let (_, shrunk) = try await writer.writeInPlace(
            try await edited(file) { $0.artwork = [] }, at: file, fallback: .refuse)
        let shrunk0 = try #require(shrunk)
        #expect(shrunk0.compacted)
        #expect(shrunk0.moovOffset == moovBefore.offset, "the moov did not come back to the front")
        let afterShrink = try table(of: file)
        #expect(afterShrink.map(\.type) == ["ftyp", "moov", "free", "mdat"], "\(afterShrink)")
        #expect(try fileSize(file) == lengthBefore)
        #expect(try bytes(of: "mdat", in: file) == mdatBefore)
        try await expectReadable(file)
    }

    /// A slot bigger than the new moov by less than a free atom's header
    /// cannot take a free atom. The moov is made exactly that much longer.
    @Test("a slot bigger by one to seven bytes is filled by padding the moov")
    func tinyGapIsPadded() async throws {
        for gap in [1, 3, 7] {
            let file = try await fastStartM4A("inplace-gap-\(gap)")
            // A write that drops the cover first: the moov is then this
            // module's own layout, unpadded, with a free atom after it, so
            // the arithmetic below is exact.
            _ = try await writer.writeInPlace(try await edited(file) { $0.artwork = [] }, at: file, fallback: .refuse)
            let lengthBefore = try fileSize(file)
            let before = try table(of: file)
            #expect(before.map(\.type) == ["ftyp", "moov", "free", "mdat"], "gap \(gap): \(before)")
            let moovBefore = try #require(before.first { $0.type == "moov" })
            let slot = moovBefore.size + (before.first { $0.type == "free" }?.size ?? 0)
            // A comment of n bytes adds an item of 24 + n, so the slot is
            // bigger than the new moov by exactly `gap` for the right n.
            let n = Int(slot - moovBefore.size - 24 - UInt64(gap))
            let (_, report) = try await writer.writeInPlace(
                try await edited(file) { $0.comment = String(repeating: "c", count: n) },
                at: file, fallback: .refuse)
            let report0 = try #require(report)
            #expect(report0.compacted, "gap \(gap)")
            #expect(report0.moovOffset == moovBefore.offset, "gap \(gap)")
            let after = try table(of: file)
            #expect(after.map(\.type) == ["ftyp", "moov", "mdat"], "gap \(gap): \(after)")
            #expect(try fileSize(file) == lengthBefore, "gap \(gap)")
            #expect(try await reader.read(file).comment?.count == n)
            try await expectReadable(file)
        }
    }

    // MARK: - Interruption

    /// Stopped at any forced-write boundary, the file still plays and still
    /// reads as either the old tags or the new ones, never garbage; and the
    /// next write heals whatever was left.
    @Test("an interruption at every step leaves a readable file that the next write heals")
    func interruptionsLeaveReadableFiles() async throws {
        for layout in [Layout.moovLast, .fastStart] {
            for step in MP4InPlace.Step.allCases {
                let file = try await fixture(layout, "inplace-interrupt-\(layout)-\(step)")
                let original = try await reader.read(file)
                let cover = try #require(Artwork(sniffing: try Self.noisePNG(side: 128)))
                var edit = original
                edit.title = "Interrupted"
                edit.artwork = [cover]

                struct Stop: Error {}
                let hooks = MP4InPlace.Hooks { reached in
                    if reached == step { throw Stop() }
                }
                var stopped = false
                do {
                    _ = try await writer.writeInPlace(edit, at: file, fallback: .refuse, hooks: hooks)
                } catch is Stop {
                    stopped = true
                }
                // Not every step happens for every layout; the ones that do
                // must have stopped there.
                let read = try await reader.read(file)
                #expect(read.title == original.title || read.title == "Interrupted",
                        "\(layout) at \(step): read \(String(describing: read.title))")
                try await expectReadable(file, label: "\(layout) after \(step)")

                // Then the write is run again, which heals and finishes.
                let (result, report) = try await writer.writeInPlace(edit, at: file, fallback: .refuse)
                #expect(result.wroteInPlace)
                #expect(try await reader.read(file).title == "Interrupted", "\(layout) healing after \(step)")
                let after = try table(of: file)
                #expect(after.filter { $0.type == "moov" }.count == 1, "\(layout) after \(step): \(after)")
                #expect(after.last?.end == (try fileSize(file)), "\(layout) after \(step): table does not tile the file")
                try await expectReadable(file, label: "\(layout) healed after \(step)")
                _ = stopped
                _ = report
            }
        }
    }

    /// A crash *during* the append — not at a boundary — is a partial atom on
    /// the end of a file whose own moov is intact.
    @Test("a file truncated in the middle of the appended copy still plays, and the next write cuts the stump off")
    func partialAppendIsCutOff() async throws {
        let file = try await m4a("inplace-stump")
        let length = try fileSize(file)
        let original = try await reader.read(file)

        struct Stop: Error {}
        let hooks = MP4InPlace.Hooks { reached in
            if reached == .appendedCopy { throw Stop() }
        }
        var edit = original
        edit.title = "Stump"
        do {
            _ = try await writer.writeInPlace(edit, at: file, fallback: .refuse, hooks: hooks)
        } catch is Stop {}
        // Cut the appended copy in half.
        let handle = try FileHandle(forUpdating: file)
        let grown = try handle.seekToEnd()
        #expect(grown > length)
        try handle.truncate(atOffset: length + (grown - length) / 2)
        try handle.close()

        #expect(try await reader.read(file).title == original.title)
        try await expectReadable(file, label: "with a stump")
        let (boxes, partial) = try ISOBMFF.topLevel(of: try ISOFileReader(url: file))
        #expect(partial == length)
        #expect(boxes.last?.end == length)

        _ = try await writer.writeInPlace(edit, at: file, fallback: .refuse)
        #expect(try await reader.read(file).title == "Stump")
        let after = try table(of: file)
        #expect(after.last?.end == (try fileSize(file)))
        try await expectReadable(file, label: "healed")
    }

    // MARK: - The decision table

    @Test("every MP4-family layout is supported, and nothing else is")
    func supportedFiles() async throws {
        #expect(writer.canWriteInPlace(at: try await m4a("inplace-support-m4a")).isSupported)
        #expect(writer.canWriteInPlace(at: try await fastStartM4A("inplace-support-fast")).isSupported)
        #expect(writer.canWriteInPlace(at: try await mov("inplace-support-mov")).isSupported)
        #expect(writer.canWriteInPlace(at: try await mp4("inplace-support-mp4")).isSupported)

        let directory = try DocumentFixtures.makeTemporaryDirectory("inplace-unsupported")
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpeg = try DocumentFixtures.write(
            try DocumentFixtures.solidJPEG(), to: directory.appendingPathComponent("a.jpg"))
        #expect(writer.canWriteInPlace(at: jpeg).reason?.contains("not in a moov atom") == true)
        var mp3 = Data([0xFF, 0xFB, 0x90, 0x00])
        mp3.append(Data(repeating: 0x5A, count: 500))
        let mp3URL = try DocumentFixtures.write(mp3, to: directory.appendingPathComponent("a.mp3"))
        #expect(writer.canWriteInPlace(at: mp3URL).reason?.contains("ID3") == true)
        #expect(!writer.canWriteInPlace(at: directory.appendingPathComponent("absent.mp4")).isSupported)
    }

    @Test("a fragmented file, an open-ended atom, two moovs, and keyed user data are refused by name")
    func refusals() async throws {
        // Fragmented: a moof anywhere at the top level.
        let fragmented = try await m4a("inplace-refuse-moof")
        try append(ISOBMFF.box("moof", Data(repeating: 0, count: 8)), to: fragmented)
        #expect(writer.canWriteInPlace(at: fragmented).reason?.contains("fragmented") == true)

        // The last atom's size field zeroed: "to the end of the file".
        let open = try await m4a("inplace-refuse-open")
        let moov = try #require(try table(of: open).first { $0.type == "moov" })
        try patch(open, at: moov.offset, with: Data([0, 0, 0, 0]))
        #expect(writer.canWriteInPlace(at: open).reason?.contains("extends to the end") == true)

        // Two moovs, neither the trailing copy an interrupted write leaves.
        let doubled = try await m4a("inplace-refuse-double")
        let copy = try Data(contentsOf: doubled).subdata(in: Int(moov.offset)..<Int(moov.end))
        try append(copy + ISOBMFF.box("free", Data()), to: doubled)
        #expect(writer.canWriteInPlace(at: doubled).reason?.contains("2 moov atoms") == true)

        // udta/meta in QuickTime's key/value form rather than iTunes atoms.
        let keyed = try await m4a("inplace-refuse-keys")
        var hdlr = Data(repeating: 0, count: 8)
        hdlr.append(ISOBMFF.fourCC("mdta"))
        hdlr.append(Data(repeating: 0, count: 13))
        let meta = ISOBMFF.box("meta", Data([0, 0, 0, 0]) + ISOBMFF.box("hdlr", hdlr)
            + ISOBMFF.box("keys", Data([0, 0, 0, 0, 0, 0, 0, 0])) + ISOBMFF.box("ilst", Data()))
        try replaceUserData(in: keyed, with: ISOBMFF.box("udta", meta))
        #expect(writer.canWriteInPlace(at: keyed).reason?.contains("mdta") == true)
        try await expectReadable(keyed, label: "the keyed fixture itself")
    }

    /// The leftovers of an interrupted write are not refusals: a trailing
    /// stump and a duplicate trailing moov are both cut off by the next write.
    @Test("a trailing stump or a duplicate trailing moov is healed, not refused")
    func leftoversAreHealed() async throws {
        let stumped = try await m4a("inplace-heal-stump")
        try append(Data([0, 0, 1, 0]) + ISOBMFF.fourCC("moov") + Data(repeating: 7, count: 40), to: stumped)
        #expect(writer.canWriteInPlace(at: stumped).isSupported)
        let length = try fileSize(stumped)
        _ = try await writer.writeInPlace(try await edited(stumped) { $0.title = "Healed" }, at: stumped, fallback: .refuse)
        #expect(try fileSize(stumped) < length)
        #expect(try table(of: stumped).last?.end == (try fileSize(stumped)))
        #expect(try await reader.read(stumped).title == "Healed")

        let doubled = try await m4a("inplace-heal-double")
        let moov = try #require(try table(of: doubled).first { $0.type == "moov" })
        try append(try Data(contentsOf: doubled).subdata(in: Int(moov.offset)..<Int(moov.end)), to: doubled)
        #expect(writer.canWriteInPlace(at: doubled).isSupported)
        _ = try await writer.writeInPlace(try await edited(doubled) { $0.title = "Healed" }, at: doubled, fallback: .refuse)
        let after = try table(of: doubled)
        #expect(after.filter { $0.type == "moov" }.count == 1)
        #expect(after.last?.end == (try fileSize(doubled)))
        try await expectReadable(doubled)
    }

    /// With the default fallback, a file that cannot take the in-place path
    /// is exported and replaced; with `.refuse`, it is left alone.
    @Test("the fallback exports when allowed and refuses when not")
    func fallback() async throws {
        let fragmented = try await m4a("inplace-fallback")
        try append(ISOBMFF.box("moof", Data(repeating: 0, count: 8)), to: fragmented)
        let before = try Data(contentsOf: fragmented)

        await #expect(throws: LatheError.self) {
            try await writer.write(MediaMetadata(title: "Refused"), inPlaceAt: fragmented, fallback: .refuse)
        }
        #expect(try Data(contentsOf: fragmented) == before, "a refusal changed the file")

        let result = try await writer.write(MediaMetadata(title: "Exported"), inPlaceAt: fragmented)
        #expect(!result.wroteInPlace)
        #expect(result.output == fragmented)
        #expect(try await reader.read(fragmented).title == "Exported")
        #expect(!(try table(of: fragmented)).contains { $0.type == "moof" })
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fragmented.deletingLastPathComponent().path)
        #expect(!siblings.contains { $0.hasPrefix(".lathe-") }, "a scratch file was left behind")
    }

    // MARK: - What survives

    /// Everything the reader returned before the write and the edit did not
    /// touch reads back unchanged afterwards — the artwork bytes and the
    /// fields this module has no name for included.
    @Test("every field the edit did not touch reads back unchanged, custom ones included")
    func roundTripKeepsEverythingElse() async throws {
        let file = try await m4a("inplace-roundtrip")
        var before = try await reader.read(file)
        #expect(!before.custom.isEmpty, "the fixture carries no custom field to preserve: \(before)")
        #expect(before.artwork.count == 1)

        var edit = before
        edit.title = "Only This Changed"
        let result = try await writer.write(edit, inPlaceAt: file, fallback: .refuse)
        #expect(result.wroteInPlace)

        let after = try await reader.read(file)
        before.title = "Only This Changed"
        #expect(after == before, "\(after)\n!=\n\(before)")
    }

    /// A QuickTime movie's own keyed metadata: the creation date it keeps
    /// there would compete with `©day`, so it goes; the location does not,
    /// so it stays.
    @Test("a movie's keyed metadata keeps what does not compete with the tags")
    func quickTimeKeysAreKeptUnlessTheyCompete() async throws {
        let file = try await mov("inplace-keys")
        let before = try await reader.read(file)
        let date = try #require(before.date)
        #expect(before.custom["mdta/com.apple.quicktime.location.ISO6709"] == "+37.7749-122.4194/")

        var edit = before
        edit.title = "Located"
        edit.date = date.addingTimeInterval(86_400)
        _ = try await writer.write(edit, inPlaceAt: file, fallback: .refuse)

        let after = try await reader.read(file)
        #expect(after.title == "Located")
        #expect(after.date.map { Int($0.timeIntervalSince1970) } == Int(date.timeIntervalSince1970) + 86_400)
        #expect(after.custom["mdta/com.apple.quicktime.location.ISO6709"] == "+37.7749-122.4194/")
        try await expectReadable(file)
    }

    /// User data a reader would show as the same fields — the 3GPP `titl`
    /// and `thmb` a plain MPEG-4 export writes beside the tags — is dropped,
    /// so a cleared title stays cleared.
    @Test("competing user-data atoms are dropped so a cleared field stays cleared")
    func competingUserDataIsDropped() async throws {
        let file = try await m4a("inplace-titl")
        // A 3GPP title beside the iTunes one, as macOS's plain MPEG-4 export leaves.
        let old = try #require(try userData(in: file))
        var titl = Data([0, 0, 0, 0, 0x55, 0xC4])
        titl.append(Data("Leftover".utf8) + Data([0]))
        try replaceUserData(in: file, with: ISOBMFF.box("udta", old.payload + ISOBMFF.box("titl", titl)))
        #expect(try await reader.read(file).title == "T", "the fixture's iTunes title still wins")

        _ = try await writer.write(try await edited(file) { $0.title = nil }, inPlaceAt: file, fallback: .refuse)
        let after = try await reader.read(file)
        #expect(after.title == nil, "the cleared title came back as \(String(describing: after.title))")
        #expect(after.creators == ["A"])
        try await expectReadable(file)
    }

    /// AVFoundation's own view of the result agrees with the reader's.
    @Test("AVFoundation reads the rewritten tags as written")
    func avFoundationAgrees() async throws {
        let file = try await mp4("inplace-avf")
        let cover = try #require(Artwork(sniffing: try Self.noisePNG(side: 64)))
        var meta = MediaMetadata(title: "Agreed", creators: ["One", "Two"], genre: "Drama", kind: .tvShow)
        meta.show = ShowInfo(seriesName: "A Series", seasonNumber: 3, episodeNumber: 12, episodeID: "312", network: "Net")
        meta.track = TrackInfo(albumName: "Album", trackNumber: 4, trackCount: 9, discNumber: 1, discCount: 2, isCompilation: true)
        meta.artwork = [cover]
        meta.date = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await writer.write(meta, inPlaceAt: file, fallback: .refuse)

        let items = try await AVURLAsset(url: file).load(.metadata)
        func value(_ identifier: String) async -> Any? {
            guard let item = items.first(where: { $0.identifier?.rawValue == identifier }) else { return nil }
            return try? await item.load(.value)
        }
        #expect(await value("itsk/%A9nam") as? String == "Agreed")
        #expect(await value("itsk/%A9ART") as? String == "One, Two")
        #expect((await value("itsk/stik") as? NSNumber)?.intValue == MediaKind.tvShow.rawValue)
        #expect((await value("itsk/tvsn") as? NSNumber)?.intValue == 3)
        #expect((await value("itsk/tves") as? NSNumber)?.intValue == 12)
        #expect((await value("itsk/cpil") as? NSNumber)?.intValue == 1)
        #expect(await value("itsk/covr") as? Data == cover.data)
        #expect(await value("itsk/%A9day") as? String == "2023-11-14T22:13:20Z")
        let trkn = try #require(await value("itsk/trkn") as? Data)
        #expect([UInt8](trkn) == [0, 0, 0, 4, 0, 9, 0, 0])

        let read = try await reader.read(file)
        #expect(read.title == "Agreed")
        #expect(read.show?.seriesName == "A Series")
        #expect(read.track?.trackNumber == 4)
        #expect(read.artwork.first?.data == cover.data)
    }

    /// Several covers are one `covr` atom with several `data` children, and
    /// come back as several.
    @Test("several covers survive in order")
    func severalCovers() async throws {
        let file = try await m4a("inplace-covers")
        let a = try #require(Artwork(sniffing: try Self.noisePNG(side: 32)))
        let b = try #require(Artwork(sniffing: try DocumentFixtures.solidJPEG()))
        _ = try await writer.write(try await edited(file) { $0.artwork = [a, b] }, inPlaceAt: file, fallback: .refuse)
        let read = try await reader.read(file)
        #expect(read.artwork.map(\.data) == [a.data, b.data])
        #expect(read.artwork.map(\.format) == [.png, .jpeg])
    }

    /// The samples never move and never change — proven by reading them
    /// back through AVFoundation after the write, not only by comparing
    /// `mdat`.
    @Test("the samples read back identical after an in-place write")
    func samplesAreUntouched() async throws {
        let file = try await m4a("inplace-samples")
        let before = try await sampleBytes(of: file)
        #expect(!before.isEmpty)
        let cover = try #require(Artwork(sniffing: try Self.noisePNG(side: 512)))
        _ = try await writer.write(try await edited(file) { $0.artwork = [cover]; $0.title = "Samples" }, inPlaceAt: file, fallback: .refuse)
        #expect(try await sampleBytes(of: file) == before)
    }

    /// A chapter track is a track, and tracks are copied unread.
    @Test("chapters survive an in-place tag write")
    func chaptersSurvive() async throws {
        let source = try await FixtureLibrary.shared.aacFile(
            named: "inplace-chapters-source.m4a", seconds: 4, title: "Tone", artist: "Lathe")
        let chaptered = await FixtureLibrary.shared.scratchURL(named: "inplace-chapters.m4a")
        try? FileManager.default.removeItem(at: chaptered)
        let chapters = [
            Chapter(startSeconds: 0, durationSeconds: 2, title: "One"),
            Chapter(startSeconds: 2, durationSeconds: 2, title: "Two"),
        ]
        _ = try await ChapterWriter().write(chapters, into: source, writingTo: chaptered)
        #expect(await ChapterTrack.read(from: AVURLAsset(url: chaptered)).map(\.title) == ["One", "Two"])

        let result = try await writer.write(try await edited(chaptered) { $0.title = "Chaptered" }, inPlaceAt: chaptered, fallback: .refuse)
        #expect(result.wroteInPlace)
        #expect(await ChapterTrack.read(from: AVURLAsset(url: chaptered)).map(\.title) == ["One", "Two"])
        #expect(try await reader.read(chaptered).title == "Chaptered")
    }

    /// `update(inPlaceAt:)` is the read-modify-write shape.
    @Test("update in place reads, edits and writes")
    func updateInPlace() async throws {
        let file = try await m4a("inplace-update")
        let result = try await writer.update(inPlaceAt: file, fallback: .refuse) { $0.comment = "Updated" }
        #expect(result.wroteInPlace)
        let read = try await reader.read(file)
        #expect(read.comment == "Updated")
        #expect(read.title == "T")
    }

    // MARK: - The measurement

    /// How much a title change writes when the file carries a multi-megabyte
    /// cover — the number that justifies this path. Printed to the test log.
    @Test("a tag change writes the moov and nothing else, and says how much that was")
    func bytesWrittenForATitleChange() async throws {
        let file = try await m4a("inplace-measure")
        let cover = try #require(Artwork(sniffing: try Self.noisePNG(side: 1024)))
        #expect(cover.data.count > 2_000_000, "the cover is \(cover.data.count) bytes; wanted a multi-MB one")
        _ = try await writer.write(try await edited(file) { $0.artwork = [cover] }, inPlaceAt: file, fallback: .refuse)
        let size = try fileSize(file)
        let moov = try #require(try table(of: file).first { $0.type == "moov" })

        let started = Date()
        let result = try await writer.write(try await edited(file) { $0.title = "Measured" }, inPlaceAt: file, fallback: .refuse)
        let seconds = Date().timeIntervalSince(started)
        #expect(result.wroteInPlace)
        #expect(result.bytesWritten < 3 * moov.size + 64)
        #expect(result.bytesWritten >= 2 * moov.size)

        let exported = await FixtureLibrary.shared.scratchURL(named: "inplace-measure-export.m4a")
        try? FileManager.default.removeItem(at: exported)
        let export = try await writer.write(try await edited(file) { $0.title = "Exported" }, to: file, writingTo: exported)

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        func n(_ value: UInt64) -> String { formatter.string(from: NSNumber(value: value)) ?? "\(value)" }
        // To stderr: the test runner swallows stdout, and this number is the
        // point of the path.
        let line = "[measurement] in-place title change: file \(n(size)) bytes, moov \(n(moov.size)) bytes "
            + "(cover \(n(UInt64(cover.data.count)))), wrote \(n(result.bytesWritten)) bytes "
            + "in \(String(format: "%.3f", seconds)) s; the export wrote \(n(export.bytesWritten)) bytes\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    // MARK: - Fixtures

    enum Layout: CustomStringConvertible {
        case moovLast, fastStart
        var description: String { self == .moovLast ? "moov-last" : "fast-start" }
    }

    private func fixture(_ layout: Layout, _ name: String) async throws -> URL {
        switch layout {
        case .moovLast: return try await m4a(name)
        case .fastStart: return try await fastStartM4A(name)
        }
    }

    /// A private copy of the tagged AAC fixture — moov last, as AVAssetWriter
    /// leaves it, with a title, artist, album, a small cover and the gapless
    /// `----` item the encoder adds.
    private func m4a(_ name: String) async throws -> URL {
        let source = try await FixtureLibrary.shared.aacFile(
            named: "inplace-source.m4a", seconds: 1, title: "T", artist: "A", album: "B", artwork: true)
        return try await copy(source, as: "\(name).m4a")
    }

    /// The same, with the moov moved in front of mdat.
    private func fastStartM4A(_ name: String) async throws -> URL {
        let source = try await m4a("inplace-fast-source")
        let destination = await FixtureLibrary.shared.scratchURL(named: "\(name).m4a")
        try? FileManager.default.removeItem(at: destination)
        try Relayout.fastStart(source, to: destination)
        #expect(try table(of: destination).map(\.type) == ["ftyp", "moov", "mdat"])
        try await expectReadable(destination, label: "the fast-start fixture")
        return destination
    }

    /// A QuickTime movie with a creation date and a location in its own
    /// keyed metadata.
    private func mov(_ name: String) async throws -> URL {
        let source = try await FixtureLibrary.shared.movie(
            named: "inplace-source.mov", seconds: 1, audio: .tone(hertz: 440, amplitude: 0.3),
            creationDate: Date(timeIntervalSince1970: 1_600_000_000), location: "+37.7749-122.4194/")
        return try await copy(source, as: "\(name).mov")
    }

    /// A plain MP4, by way of the export.
    private func mp4(_ name: String) async throws -> URL {
        let mov = try await FixtureLibrary.shared.movie(named: "inplace-source.mov", seconds: 1,
            audio: .tone(hertz: 440, amplitude: 0.3),
            creationDate: Date(timeIntervalSince1970: 1_600_000_000), location: "+37.7749-122.4194/")
        let destination = await FixtureLibrary.shared.scratchURL(named: "\(name).mp4")
        try? FileManager.default.removeItem(at: destination)
        _ = try await writer.write(MediaMetadata(title: "MP4"), to: mov, writingTo: destination)
        return destination
    }

    private func copy(_ source: URL, as name: String) async throws -> URL {
        let destination = await FixtureLibrary.shared.scratchURL(named: name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func edited(_ url: URL, _ edit: (inout MediaMetadata) -> Void) async throws -> MediaMetadata {
        var metadata = try await reader.read(url)
        edit(&metadata)
        return metadata
    }

    /// A PNG of noise, which does not compress: about four bytes a pixel.
    static func noisePNG(side: Int) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15 &+ UInt64(side)
        for index in pixels.indices {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            pixels[index] = UInt8(truncatingIfNeeded: state)
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let out = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)
        else { throw FixtureError.unsupported("could not make a PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.unsupported("could not finalise a PNG") }
        return out as Data
    }

    // MARK: - Looking at files

    private func table(of url: URL) throws -> [ISOBox] {
        try ISOBMFF.topLevel(of: try ISOFileReader(url: url)).boxes
    }

    /// Through FileManager, not `resourceValues`: a URL caches those, and a
    /// size asked for before a write came back again after it.
    private func fileSize(_ url: URL) throws -> UInt64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    private func bytes(of type: String, in url: URL) throws -> Data {
        let box = try #require(try table(of: url).first { $0.type == type })
        return try ISOFileReader(url: url).readExactly(at: box.offset, count: Int(box.size))
    }

    private func userData(in url: URL) throws -> (box: ISOBox, payload: Data)? {
        let inspection = try MP4InPlace.inspect(url)
        guard let udta = inspection.moovChildren.first(where: { $0.type == "udta" }) else { return nil }
        let raw = inspection.bytes(of: udta)
        return (udta, raw.subdata(in: Int(udta.headerSize)..<raw.count))
    }

    /// Swaps the moov's udta for `udta`, rewriting the moov where it is —
    /// the fixture is moov-last, so the file just ends in a different place.
    private func replaceUserData(in url: URL, with udta: Data) throws {
        let inspection = try MP4InPlace.inspect(url)
        var payload = Data()
        for child in inspection.moovChildren {
            if child.type == "udta" { payload.append(udta) } else { payload.append(inspection.bytes(of: child)) }
        }
        let moov = ISOBMFF.box("moov", payload)
        let handle = try FileHandle(forUpdating: url)
        try handle.truncate(atOffset: inspection.moov.offset)
        try handle.seek(toOffset: inspection.moov.offset)
        try handle.write(contentsOf: moov)
        try handle.close()
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    private func patch(_ url: URL, at offset: UInt64, with data: Data) throws {
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: data)
        try handle.close()
    }

    /// Playable, with its tracks, and readable through the reader.
    private func expectReadable(_ url: URL, label: String = "") async throws {
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let tracks = try await asset.load(.tracks)
        #expect(playable, "\(label): not playable")
        #expect(!tracks.isEmpty, "\(label): no tracks")
        _ = try await reader.read(url)
    }

    /// Every compressed sample of the first audio track, byte for byte.
    private func sampleBytes(of url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return Data() }
        let assetReader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        assetReader.add(output)
        assetReader.startReading()
        var collected = Data()
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer
            ) == noErr, let pointer else { continue }
            collected.append(UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: length)
        }
        return collected
    }
}

/// Moves a file's `moov` in front of its `mdat` — the fast-start layout — by
/// shifting every chunk offset in every sample table by what moved in front
/// of the samples. A test fixture generator; the library never moves `mdat`.
enum Relayout {
    static func fastStart(_ source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        let (boxes, _) = try ISOBMFF.topLevel(of: try ISOFileReader(url: source))
        guard let moov = boxes.first(where: { $0.type == "moov" }),
              let mdat = boxes.first(where: { $0.type == "mdat" }), moov.offset > mdat.offset
        else {
            try data.write(to: destination)
            return
        }
        var moovBytes = data.subdata(in: Int(moov.offset)..<Int(moov.end))
        try shiftChunkOffsets(in: &moovBytes, range: Int(moov.headerSize)..<moovBytes.count, by: Int64(moov.size), parent: "moov")

        var out = Data()
        var inserted = false
        for box in boxes where box.offset != moov.offset {
            if !inserted, box.type != "ftyp" {
                out.append(moovBytes)
                inserted = true
            }
            out.append(data.subdata(in: Int(box.offset)..<Int(box.end)))
        }
        if !inserted { out.append(moovBytes) }
        try out.write(to: destination)
    }

    private static let containers: Set<String> = ["trak", "mdia", "minf", "stbl"]

    private static func shiftChunkOffsets(in data: inout Data, range: Range<Int>, by delta: Int64, parent: String) throws {
        let children = try ISOBMFF.children(of: data.subdata(in: range), base: UInt64(range.lowerBound), in: parent)
        for child in children {
            let start = Int(child.offset)
            let payload = start + Int(child.headerSize)
            switch child.type {
            case "stco", "co64":
                let count = Int(ISOBMFF.uint32(data, at: payload + 4))
                var cursor = payload + 8
                for _ in 0..<count {
                    if child.type == "stco" {
                        let value = Int64(ISOBMFF.uint32(data, at: cursor)) + delta
                        data.replaceSubrange(cursor..<cursor + 4, with: ISOBMFF.bytes(UInt32(value)))
                        cursor += 4
                    } else {
                        let value = Int64(ISOBMFF.uint64(data, at: cursor)) + delta
                        data.replaceSubrange(cursor..<cursor + 8, with: ISOBMFF.bytes(UInt64(value)))
                        cursor += 8
                    }
                }
            case let type where containers.contains(type):
                try shiftChunkOffsets(in: &data, range: payload..<start + Int(child.size), by: delta, parent: type)
            default:
                continue
            }
        }
    }
}
