import CLAME
import Foundation
import LatheCore

/// A configured LAME encoder, and the only place this package touches its C API.
///
/// A class rather than a struct because LAME's handle is an opaque pointer with
/// a matching close call, and `deinit` is what guarantees the close happens on
/// every path out — including a thrown error part-way through an encode.
///
/// ## The output buffer rule
///
/// LAME's documented worst case for a call is `1.25 * frames + 7200` bytes, and
/// "worst case" is not decoration: the encoder buffers across calls and can
/// return far more than one frame's worth at once, or nothing at all. A buffer
/// sized to the input rather than to that formula works on ordinary audio and
/// corrupts the output on the unusual frame, which is a bug that appears only in
/// somebody's library.
final class LAMEFlags {

    private let handle: OpaquePointer
    private var closed = false

    init(sampleRate: Int, channels: Int, quality: QualityTarget, mode: MP3Mode) throws {
        guard let handle = lame_init() else {
            throw LatheError.encodeUnavailable(format: "mp3 (LAME would not initialise)")
        }
        self.handle = handle

        lame_set_in_samplerate(handle, Int32(sampleRate))
        lame_set_out_samplerate(handle, Int32(sampleRate))
        lame_set_num_channels(handle, Int32(channels))
        lame_set_mode(handle, mode.lameMode(channels: channels))

        // VBR, chosen rather than a constant bitrate: it spends bits where the
        // audio needs them, and at a given size it is simply better. A caller
        // who needs a predictable byte count for a streaming slot wants CBR and
        // does not have it here yet.
        switch quality {
        case .averageBitrate(let bitsPerSecond):
            lame_set_VBR(handle, vbr_abr)
            lame_set_VBR_mean_bitrate_kbps(handle, Int32(max(8, bitsPerSecond / 1_000)))
        case .lossless:
            // There is no lossless MP3. Refused rather than silently encoded at
            // the highest setting, which would be a lossy file wearing the name
            // the caller asked to avoid.
            lame_close(handle)
            closed = true
            throw LatheError.invalidInput(
                reason: "MP3 has no lossless mode; ask for ALAC or FLAC instead"
            )
        case .quality(let value), .constantQualityFactor(let value):
            lame_set_VBR(handle, vbr_default)
            lame_set_VBR_quality(handle, Float(Self.vbrQuality(from: value)))
        }

        // 0 is the slowest and best analysis, 9 the fastest. 2 is LAME's own
        // recommended setting for quality work and is far from the cliff at the
        // fast end; the difference from 0 is not audible and is several times
        // the encoding time.
        lame_set_quality(handle, 2)
        // Write the Xing/LAME header, which is what lets a player seek a VBR
        // file and report its duration correctly. Without it, a VBR MP3 shows a
        // wrong length in most players.
        lame_set_bWriteVbrTag(handle, 1)

        guard lame_init_params(handle) >= 0 else {
            lame_close(handle)
            closed = true
            throw LatheError.invalidConfiguration(
                reason: "LAME refused \(sampleRate) Hz at \(channels) channel(s)"
            )
        }
    }

    deinit {
        if !closed { lame_close(handle) }
    }

    /// LAME's VBR scale runs 0 (best) to 9 (worst), which is the opposite
    /// direction from every quality knob in this package.
    ///
    /// Inverted here rather than at the call site, because a caller passing 0.9
    /// and getting a poor file would have no way to tell whether the scale or
    /// the encoder was at fault.
    static func vbrQuality(from normalised: Double) -> Int {
        let clamped = min(max(normalised, 0), 1)
        return Int((1 - clamped) * 9).clampedToVBR
    }

    /// Encodes one block of interleaved 16-bit samples.
    func encode(_ samples: [Int16], frames: Int, channels: Int) throws -> Data {
        var output = [UInt8](repeating: 0, count: Self.outputCapacity(frames: frames))
        let written = samples.withUnsafeBufferPointer { input -> Int32 in
            output.withUnsafeMutableBufferPointer { buffer in
                guard let inBase = input.baseAddress, let outBase = buffer.baseAddress else {
                    return 0
                }
                if channels == 1 {
                    // The mono entry point, not interleaved-stereo with one
                    // channel: handing lame_encode_buffer_interleaved a mono
                    // block makes it read two channels' worth of samples for
                    // every frame and run off the end of the array.
                    return lame_encode_buffer(
                        handle, inBase, inBase, Int32(frames), outBase, Int32(buffer.count)
                    )
                }
                return lame_encode_buffer_interleaved(
                    handle, UnsafeMutablePointer(mutating: inBase), Int32(frames),
                    outBase, Int32(buffer.count)
                )
            }
        }
        guard written >= 0 else {
            throw LatheError.encodingFailed(
                stage: "mp3-encode", code: written, reason: Self.reason(for: written)
            )
        }
        return Data(output.prefix(Int(written)))
    }

    /// The encoder's final frame.
    func flush() throws -> Data {
        var output = [UInt8](repeating: 0, count: 7_200)
        let written = output.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            return lame_encode_flush(handle, base, Int32(buffer.count))
        }
        guard written >= 0 else {
            throw LatheError.encodingFailed(
                stage: "mp3-flush", code: written, reason: Self.reason(for: written)
            )
        }
        return Data(output.prefix(Int(written)))
    }

    /// Writes the Xing/LAME header over the start of the finished file.
    ///
    /// It has to go back to offset zero, because the header records totals —
    /// frame count, byte count, the seek table — that are only known once the
    /// last frame is written. This is why the encode goes to a seekable scratch
    /// file rather than streaming.
    func writeVBRHeader(to handle: FileHandle) throws {
        // Asked for twice on purpose: the first call with a zero-length buffer
        // reports how big the tag is, the second fills it. LAME documents this,
        // and guessing a size instead would either truncate the seek table or
        // waste a frame-sized allocation on every encode.
        let needed = lame_get_lametag_frame(self.handle, nil, 0)
        guard needed > 0 else {
            // No tag is not a failure: a CBR encode has none, and a file without
            // one still plays. It just seeks poorly.
            return
        }

        var buffer = [UInt8](repeating: 0, count: needed)
        let written = buffer.withUnsafeMutableBufferPointer { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return lame_get_lametag_frame(self.handle, base, needed)
        }
        guard written > 0 else { return }
        let tag = Data(buffer.prefix(written))
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: tag)
        } catch {
            throw LatheError.writeFailed(
                path: "the VBR header", reason: (error as NSError).localizedDescription
            )
        }
    }

    /// LAME's documented worst case for one call, which is not the same as one
    /// frame's worth. See the type's note.
    static func outputCapacity(frames: Int) -> Int {
        Int(Double(frames) * 1.25) + 7_200
    }

    private static func reason(for code: Int32) -> String {
        switch code {
        case -1: return "the output buffer was too small"
        case -2: return "LAME could not allocate memory"
        case -3: return "lame_init_params was never called"
        case -4: return "the psychoacoustic model failed"
        default: return "LAME returned \(code)"
        }
    }
}

private extension Int {
    /// LAME's VBR quality is 0…9 and nothing else.
    var clampedToVBR: Int { Swift.min(Swift.max(self, 0), 9) }
}

private extension MP3Mode {
    /// The `MPEG_mode` LAME wants.
    ///
    /// A mono source is coded as mono whatever was asked for: telling LAME to
    /// produce joint stereo from one channel makes it duplicate the channel and
    /// spend roughly twice the bits saying the same thing twice.
    func lameMode(channels: Int) -> MPEG_mode {
        guard channels > 1 else { return MONO }
        switch self {
        case .stereo: return STEREO
        case .jointStereo: return JOINT_STEREO
        case .mono: return MONO
        }
    }
}
