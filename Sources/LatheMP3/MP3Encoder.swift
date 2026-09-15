import AVFoundation
import CLAME
import Foundation
import LatheCore

/// MP3 encoding.
///
/// ## Why this is a separate product, and the only one that is
///
/// **Apple ships no MP3 encoder.** Every platform decodes MP3 and none of them
/// encodes it, so this is the one capability in Lathe that cannot come from the
/// system. Having it at all means vendoring LAME, which is LGPL — the only
/// non-permissive code in the package.
///
/// So it lives behind its own product. Naming `LatheMP3` in a dependency list is
/// how a consumer takes on that obligation; **not** naming it is how a consumer
/// proves it has not, which is a claim a licence audit can check by looking at
/// the manifest rather than at the binary. `LatheAudio` does not depend on this,
/// and the `Lathe` umbrella does not re-export it.
///
/// See `Sources/CLAME/VENDORING.md` before depending on this.
///
/// ## And a word on whether you want it
///
/// AAC beats MP3 at every bitrate and every Apple platform encodes it, so the
/// reason to choose MP3 is compatibility with hardware or services that accept
/// nothing else. That is a real reason and a narrow one. If the destination
/// understands AAC, ``LatheAudio`` produces a better file.
public struct MP3Encoder: Sendable {

    public init() {}

    /// What LAME was asked for, and what it produced.
    public struct Result: Sendable, Equatable {
        public var output: URL
        public var sampleRate: Int
        public var channels: Int
        public var mode: MP3Mode
        public var inputByteCount: UInt64
        public var outputByteCount: UInt64
        public var wallTime: TimeInterval
        /// The encoder's own version, so a file can be traced to what made it.
        public var encoderVersion: String
    }

    /// Encodes `source` to MP3 at `destination`.
    ///
    /// Reads through AVFoundation, so anything the system can decode can be
    /// converted — including a video file, whose audio track is taken.
    ///
    /// Writing is atomic: a failure part-way leaves `destination` as it was,
    /// including leaving a previous file intact.
    @discardableResult
    public func encode(
        source: URL,
        to destination: URL,
        quality: QualityTarget = .quality(0.6),
        mode: MP3Mode = .jointStereo,
        progress: ProgressHandle = .ignoring()
    ) async throws -> Result {
        let started = Date()
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            throw LatheError.invalidInput(
                reason: "an encode cannot overwrite the file it is reading"
            )
        }

        let asset = AVURLAsset(url: source)
        // Converted rather than rethrown. AVFoundation's own error for "this is
        // not a media file" is AVFoundationErrorDomain -11828, which tells a
        // caller nothing — and a file that is not media at all and a file whose
        // audio track is missing are two different problems with two different
        // answers, so they are separated here.
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw LatheError.invalidInput(
                reason: "\(source.lastPathComponent) is not a media file AVFoundation can open "
                    + "(\(LatheError.wrapping(error).errorDescription ?? "unknown reason"))"
            )
        }
        guard let track = tracks.first else {
            throw LatheError.invalidInput(
                reason: "\(source.lastPathComponent) has no audio track to encode"
            )
        }

        // Decode to interleaved 16-bit PCM, which is what LAME's short-integer
        // entry point takes. Asking AVFoundation for exactly that avoids a
        // second conversion here and a class of float-scaling mistakes.
        let sourceRate = try await Self.sampleRate(of: track)
        let sourceChannels = try await Self.channelCount(of: track)
        let channels = mode == .mono ? 1 : min(2, max(1, sourceChannels))
        let rate = Self.supportedSampleRate(nearest: sourceRate)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
        ])
        guard reader.canAdd(output) else {
            throw LatheError.decodeUnavailable(format: source.pathExtension)
        }
        reader.add(output)

        let flags = try LAMEFlags(
            sampleRate: rate, channels: channels, quality: quality, mode: mode
        )
        let inputBytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        let duration = (try? await asset.load(.duration))?.seconds ?? 0

        let outputBytes = try MP3Files.writingAtomically(
            to: destination, stage: "mp3-encode"
        ) { scratch in
            guard let handle = FileManager.default.createFile(atPath: scratch.path, contents: nil)
                ? try? FileHandle(forWritingTo: scratch) : nil
            else {
                throw LatheError.writeFailed(path: scratch.lastPathComponent, reason: "could not open")
            }
            defer { try? handle.close() }

            guard reader.startReading() else {
                throw LatheError.wrapping(reader.error ?? LatheError.encodingFailed(
                    stage: "decode", code: nil, reason: "the reader refused to start"
                ))
            }

            var encodedSeconds: Double = 0
            while let buffer = output.copyNextSampleBuffer() {
                try progress.checkCancellation()
                guard let pcm = Self.interleavedPCM(from: buffer) else { continue }
                let frames = pcm.count / channels
                guard frames > 0 else { continue }

                let encoded = try flags.encode(pcm, frames: frames, channels: channels)
                if !encoded.isEmpty { try handle.write(contentsOf: encoded) }

                encodedSeconds += Double(frames) / Double(rate)
                if duration > 0 {
                    try progress.checkpoint(LatheProgress(
                        fraction: min(1, encodedSeconds / duration), stage: "encode"
                    ))
                }
            }

            if reader.status == .failed {
                throw LatheError.wrapping(reader.error ?? LatheError.encodingFailed(
                    stage: "decode", code: nil, reason: "the reader failed"
                ))
            }

            // The final frame, then the Xing/LAME header. The header has to be
            // written back over the START of the file, which is why the whole
            // encode goes to a scratch file with a seekable handle rather than
            // streaming straight to the destination.
            let tail = try flags.flush()
            if !tail.isEmpty { try handle.write(contentsOf: tail) }
            try flags.writeVBRHeader(to: handle)
        }

        return Result(
            output: destination,
            sampleRate: rate,
            channels: channels,
            mode: mode,
            inputByteCount: UInt64(inputBytes),
            outputByteCount: outputBytes,
            wallTime: Date().timeIntervalSince(started),
            encoderVersion: Self.encoderVersion
        )
    }

    /// LAME's own version string.
    public static var encoderVersion: String {
        String(cString: get_lame_version())
    }

    // MARK: - Reading the source

    private static func sampleRate(of track: AVAssetTrack) async throws -> Int {
        guard let format = try await track.load(.formatDescriptions).first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        else { return 44_100 }
        let rate = Int(basic.pointee.mSampleRate)
        return rate > 0 ? rate : 44_100
    }

    private static func channelCount(of track: AVAssetTrack) async throws -> Int {
        guard let format = try await track.load(.formatDescriptions).first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        else { return 2 }
        return max(1, Int(basic.pointee.mChannelsPerFrame))
    }

    /// The nearest rate MPEG audio can actually carry.
    ///
    /// MP3 is defined for nine sample rates and no others. A 48 kHz source is
    /// fine; a 96 kHz one is not, and handing LAME a rate it cannot encode makes
    /// it refuse at initialisation with a number rather than a reason. Resampling
    /// to the nearest supported rate is done by AVFoundation on the way out of
    /// the decoder, which is both faster and better than anything done here.
    static func supportedSampleRate(nearest rate: Int) -> Int {
        let supported = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
        if supported.contains(rate) { return rate }
        // Prefer rounding UP to the next supported rate: downsampling throws
        // away content the caller did not ask to lose, and 44_100 is the
        // sensible ceiling for anything higher.
        return supported.first { $0 >= rate } ?? 44_100
    }

    /// The buffer's samples as interleaved 16-bit integers.
    private static func interleavedPCM(from buffer: CMSampleBuffer) -> [Int16]? {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &length, dataPointerOut: &pointer
        ) == noErr, let pointer, length > 0 else { return nil }

        let count = length / MemoryLayout<Int16>.size
        return UnsafeRawPointer(pointer).withMemoryRebound(to: Int16.self, capacity: count) {
            Array(UnsafeBufferPointer(start: $0, count: count))
        }
    }
}

/// How the two channels are coded.
public enum MP3Mode: String, Sendable, Equatable, CaseIterable {
    /// Independent channels. Correct where the two are genuinely unrelated.
    case stereo
    /// Lets the encoder code what the channels share once. The right default:
    /// on ordinary music it is free quality, and LAME falls back to plain
    /// stereo per frame where it would not be.
    case jointStereo
    /// One channel. Halves the bitrate and is a real loss on anything recorded
    /// in stereo, so it is never chosen automatically.
    case mono
}

/// Shared file plumbing. Restated rather than imported for the same reason the
/// other modules restate it: never leave a partial output.
enum MP3Files {
    @discardableResult
    static func writingAtomically(
        to destination: URL, stage: String, _ body: (URL) throws -> Void
    ) throws -> UInt64 {
        let directory = destination.deletingLastPathComponent()
        let scratch = directory.appendingPathComponent(".lathe-\(UUID().uuidString).mp3")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: scratch) } }

        try body(scratch)

        let size = (try? scratch.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        guard size > 0 else {
            throw LatheError.encodingFailed(
                stage: stage, code: nil, reason: "the encoder finished but produced no bytes"
            )
        }
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: scratch)
        } catch {
            throw LatheError.writeFailed(
                path: destination.lastPathComponent,
                reason: (error as NSError).localizedDescription
            )
        }
        keep = true
        return UInt64(size)
    }
}
