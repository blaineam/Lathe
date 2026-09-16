import Foundation
import LatheCore

/// Reads SWF sound tags, and turns the two recoverable cases into files.
///
/// ## Three of eight codecs come out, and that is the honest total
///
/// A SWF sound declares one of eight codecs in a four-bit field. What can be
/// done with each is not a matter of effort:
///
/// - **MP3** — copy the frames out. A `.mp3` that any player opens.
/// - **Uncompressed PCM**, in either of its two spellings — wrap in a 44-byte
///   WAV header. The samples are unchanged.
/// - **Adobe ADPCM** — *not* IMA ADPCM, despite the family resemblance, and not
///   a thing any Apple framework decodes. Recovering it means writing the
///   decoder, and a hand-written ADPCM decoder that is subtly wrong produces a
///   file full of loud noise that still opens — a worse outcome than a clear
///   refusal, because it looks like success.
/// - **Nellymoser** (three variants) — a speech codec with no published
///   specification. Every implementation is reverse-engineered.
/// - **Speex** — a real, documented codec, and a third-party library.
///
/// So ADPCM, Nellymoser and Speex are **reported and not written**. That is a
/// worse answer than extracting them and a much better one than writing a file
/// that sounds like a fault in the speaker.
enum SWFSoundDecoder {

    /// The four sample rates the two-bit `SoundRate` field can express. There is
    /// no fifth: a SWF cannot describe 48 kHz audio.
    private static let sampleRates = [5512, 11025, 22050, 44100]

    /// The fields common to `DefineSound` and the two `SoundStreamHead` tags.
    struct Description {
        let format: SWFSoundFormat
        let sampleRateHz: Int
        let bitsPerSample: Int
        let channelCount: Int
    }

    // MARK: - Parsing

    /// Reads `DefineSound`: an identifier, one packed flags byte, a sample
    /// count, and the samples.
    ///
    /// The flags are a single byte holding four fields — `UB[4]` format,
    /// `UB[2]` rate, `UB[1]` size, `UB[1]` type — most-significant bit first.
    /// Reading it as four separate bytes is the obvious mistake and yields a
    /// plausible-looking 44.1 kHz stereo header for a mono 11 kHz sound.
    static func parseDefineSound(
        _ body: SWFByteReader
    ) throws -> (characterID: UInt16, description: Description, sampleCount: UInt32, data: Data) {
        var reader = body
        let characterID = try reader.u16()
        let format = SWFSoundFormat(code: UInt8(try reader.unsignedBits(4)))
        let rateIndex = Int(try reader.unsignedBits(2))
        let bits = try reader.unsignedBits(1) == 1 ? 16 : 8
        let channels = try reader.unsignedBits(1) == 1 ? 2 : 1
        reader.alignToByte()
        let sampleCount = try reader.u32()
        let data = try reader.rest()

        return (
            characterID,
            Description(
                format: format, sampleRateHz: sampleRates[rateIndex], bitsPerSample: bits,
                channelCount: channels
            ),
            sampleCount,
            data
        )
    }

    /// Reads `SoundStreamHead` / `SoundStreamHead2`, which describe a timeline's
    /// soundtrack before its blocks arrive.
    ///
    /// The tag carries *two* descriptions: a playback one, which says how Flash
    /// should play the sound, and a stream one, which says how it is actually
    /// stored. The stream description is the one an extractor wants; taking the
    /// playback fields is a mistake that shows up only on files where the two
    /// disagree, which is most of them (playback is frequently resampled).
    static func parseStreamHead(_ body: SWFByteReader) throws -> Description {
        var reader = body
        _ = try reader.unsignedBits(4)  // reserved
        _ = try reader.unsignedBits(2)  // playback rate
        _ = try reader.unsignedBits(1)  // playback size
        _ = try reader.unsignedBits(1)  // playback type
        let format = SWFSoundFormat(code: UInt8(try reader.unsignedBits(4)))
        let rateIndex = Int(try reader.unsignedBits(2))
        let bits = try reader.unsignedBits(1) == 1 ? 16 : 8
        let channels = try reader.unsignedBits(1) == 1 ? 2 : 1
        return Description(
            format: format, sampleRateHz: sampleRates[rateIndex], bitsPerSample: bits,
            channelCount: channels
        )
    }

    /// The payload of one `SoundStreamBlock`, with its per-block preamble
    /// removed.
    ///
    /// An MP3 block begins with a `UI16` sample count and an `SI16` seek offset
    /// before its frames. Concatenating blocks without dropping those four bytes
    /// injects four bytes of noise between every pair of MP3 frames, and the
    /// result is a file that decoders resynchronise through — so it plays, badly,
    /// and the damage is easy to mistake for a bad original.
    static func streamBlockPayload(_ body: SWFByteReader, format: SWFSoundFormat) throws -> Data {
        var reader = body
        if format == .mp3 {
            guard reader.remaining >= 4 else { return Data() }
            try reader.skip(4)
        }
        return try reader.rest()
    }

    /// The MP3 frames inside a `DefineSound`, with its `SI16` seek offset
    /// removed.
    ///
    /// Note the asymmetry with a stream block, which drops *four* bytes: a
    /// `DefineSound` already states its sample count in the tag, so only the
    /// seek field precedes the frames. Using one constant for both is a
    /// two-byte error that shifts every frame header out of alignment.
    static func mp3Payload(_ data: Data) -> Data {
        guard data.count > 2 else { return Data() }
        return Data(data[(data.startIndex + 2)...])
    }

    // MARK: - WAV

    /// Wraps linear PCM samples in a canonical 44-byte WAV header.
    ///
    /// ## Two assumptions, both stated because both can be wrong
    ///
    /// **Eight-bit samples are unsigned; sixteen-bit samples are signed.** That
    /// is the convention SWF inherited from the Windows multimedia format, and
    /// it is also WAV's, which is what makes this a header-only operation with
    /// no sample conversion. If a file ever turns out to store signed bytes, the
    /// result is a 128-level DC offset that sounds like distortion.
    ///
    /// **Sound format `0` is treated as little-endian.** Format `0` is defined
    /// as the *authoring machine's* byte order, and Flash was authored on
    /// big-endian PowerPC Macs for years — which is precisely why format `3`,
    /// "little-endian, definitely", was added. There is nothing in the file that
    /// says which a format-`0` sound is, so this assumes the common case and the
    /// manifest records ``SWFSoundFormat/uncompressedNativeEndian`` rather than
    /// pretending the question was settled. A 16-bit format-`0` sound that comes
    /// out as static was authored on a Mac, and byte-swapping it will fix it.
    static func wavData(
        pcm: Data, sampleRateHz: Int, bitsPerSample: Int, channelCount: Int
    ) -> Data {
        // The declared sample count is deliberately not used to size anything
        // here: the bytes actually present are the truth, and a file that
        // overstates its sample count would otherwise produce a WAV header
        // promising data that is not there — which decoders handle by reading
        // past the end of the chunk.
        let dataLength = pcm.count
        let byteRate = sampleRateHz * channelCount * bitsPerSample / 8
        let blockAlign = channelCount * bitsPerSample / 8

        var header = Data()
        func ascii(_ text: String) { header.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: Int) {
            let v = UInt32(truncatingIfNeeded: value)
            header.append(contentsOf: [
                UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF),
                UInt8((v >> 24) & 0xFF),
            ])
        }
        func u16(_ value: Int) {
            let v = UInt16(truncatingIfNeeded: value)
            header.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
        }

        ascii("RIFF")
        u32(36 + dataLength)
        ascii("WAVE")
        ascii("fmt ")
        u32(16)
        u16(1)  // WAVE_FORMAT_PCM
        u16(channelCount)
        u32(sampleRateHz)
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        ascii("data")
        u32(dataLength)

        var file = header + pcm
        // RIFF chunks are word-aligned. The pad byte is not counted in the
        // chunk's declared length, which is why it is appended after it.
        if dataLength % 2 == 1 { file.append(0) }
        return file
    }
}
