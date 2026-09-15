import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Running things

/// One measured run of anything.
struct Timing {
    var seconds: Double
    var peakResidentBytes: UInt64
}

/// Runs a closure `repeats` times and keeps the FASTEST.
///
/// Best-of rather than mean, and the reason matters for a published table: a
/// mean on a laptop measures whatever else the machine was doing. The fastest
/// run is the one least contaminated by that, and it is what every other
/// benchmark of this kind reports — so a mean here would not be comparable with
/// the numbers a reader already has.
func best(_ repeats: Int = 3, _ body: () async throws -> Void) async rethrows -> Double {
    var fastest = Double.greatestFiniteMagnitude
    for _ in 0..<repeats {
        let started = Date()
        try await body()
        fastest = Swift.min(fastest, Date().timeIntervalSince(started))
    }
    return fastest
}

/// Runs a command line, returning its wall time and output.
///
/// The tools are run exactly as a user would run them, with no `nice`, no
/// pinning and no warm-up beyond the best-of above. Their start-up cost — a
/// process launch, a dynamic link — is INCLUDED, because that cost is real and
/// is precisely what an in-process library does not pay. It is called out in the
/// table rather than subtracted.
@discardableResult
func shell(_ arguments: [String], quiet: Bool = true) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = quiet ? pipe : FileHandle.standardError
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

func toolExists(_ name: String) -> Bool {
    (try? shell(["command", "-v", name]).status) == 0
}

func toolVersion(_ name: String, _ arguments: [String]) -> String {
    guard let out = try? shell([name] + arguments).output else { return "unknown" }
    let line = out.split(separator: "\n").first.map(String.init) ?? "unknown"
    return line.trimmingCharacters(in: .whitespaces)
}

func byteCount(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
}

func format(_ value: Double, _ places: Int = 2) -> String {
    String(format: "%.\(places)f", value)
}

/// A size difference as a percentage, negative meaning smaller.
func delta(_ a: Int, _ b: Int) -> String {
    guard b > 0 else { return "—" }
    let percent = (Double(a) - Double(b)) / Double(b) * 100
    return (percent > 0 ? "+" : "") + format(percent, 1) + "%"
}

/// A ratio expressed as "N× faster/slower", which is the shape a reader can act
/// on. A bare ratio reads as a score; this reads as a claim.
func speedup(lathe: Double, tool: Double) -> String {
    guard lathe > 0, tool > 0 else { return "—" }
    return tool >= lathe
        ? "**\(format(tool / lathe, 1))× faster**"
        : "\(format(lathe / tool, 1))× slower"
}

// MARK: - Fixtures

enum Fixtures {

    static let directory: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lathe-bench", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A detailed still. Synthetic, and deliberately hostile to an encoder: a
    /// gradient with hard edges, fine detail and grain. A photograph would
    /// compress better across the board and would not change the ordering.
    static func stillPNG(width: Int = 1920, height: Int = 1080) throws -> URL {
        let url = directory.appendingPathComponent("still-\(width)x\(height).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw BenchError.fixture("no bitmap context") }

        guard let base = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw BenchError.fixture("no bitmap data")
        }
        var seed: UInt32 = 0x1234_5678
        for y in 0..<height {
            let row = base + y * context.bytesPerRow
            for x in 0..<width {
                seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                let grain = Int(seed & 0x0F) - 8
                let gradient = (x * 255) / width
                let edge = (x / 64 % 2 == 0) ? 40 : -40
                let detail = ((x ^ y) & 0x1F) * 2
                let value = Swift.max(0, Swift.min(255, gradient + edge + detail + grain))
                let pixel = row + x * 4
                pixel[0] = UInt8(value)
                pixel[1] = UInt8(Swift.max(0, Swift.min(255, value - 25)))
                pixel[2] = UInt8(Swift.max(0, Swift.min(255, value + 20)))
                pixel[3] = 255
            }
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw BenchError.fixture("no PNG destination") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw BenchError.fixture("PNG finalize failed")
        }
        return url
    }

    /// A short 1080p clip at a near-transparent bitrate, so what the codecs
    /// below are measured against is the content rather than the source's own
    /// losses.
    static func video(seconds: Double = 5, fps: Int = 30) async throws -> URL {
        let url = directory.appendingPathComponent("source-\(Int(seconds))s.mov")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let width = 1920, height = 1080
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 60_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        for index in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { usleep(500) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            paint(buffer, frame: index, width: width, height: height)
            _ = adaptor.append(buffer, withPresentationTime:
                CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return url
    }

    /// Lossless stereo audio, because a lossy source would make every encoder
    /// below measure a second generation of loss rather than its own.
    static func audioWAV(seconds: Double = 10) throws -> URL {
        let url = directory.appendingPathComponent("source-\(Int(seconds))s.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let rate = 44_100, channels = 2
        let frames = Int(seconds * Double(rate))
        var data = Data()
        var seed: UInt32 = 0x9E37_79B9

        // White noise rather than a tone: a sine wave compresses to almost
        // nothing and would make every encoder look identical.
        var samples = [Int16]()
        samples.reserveCapacity(frames * channels)
        for _ in 0..<(frames * channels) {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            samples.append(Int16(truncatingIfNeeded: Int(seed & 0xFFFF)) / 3)
        }
        let payload = samples.withUnsafeBufferPointer { Data(buffer: $0) }

        func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

        data.append(Data("RIFF".utf8))
        data.append(le32(UInt32(36 + payload.count)))
        data.append(Data("WAVEfmt ".utf8))
        data.append(le32(16))
        data.append(le16(1))                                   // PCM
        data.append(le16(UInt16(channels)))
        data.append(le32(UInt32(rate)))
        data.append(le32(UInt32(rate * channels * 2)))         // byte rate
        data.append(le16(UInt16(channels * 2)))                // block align
        data.append(le16(16))                                  // bits
        data.append(Data("data".utf8))
        data.append(le32(UInt32(payload.count)))
        data.append(payload)
        try data.write(to: url)
        return url
    }

    private static func paint(_ buffer: CVPixelBuffer, frame: Int, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let shift = frame * 3
        var seed = UInt32(frame &* 2_654_435_761 & 0x7FFF_FFFF) | 1

        for y in 0..<height {
            let row = bytes + y * stride
            for x in 0..<width {
                seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                let grain = Int(seed & 0x0F) - 8
                let gradient = ((x + shift) * 255) / width
                let edge = ((x + shift) / 64 % 2 == 0) ? 40 : -40
                let highlight = Swift.max(0, 90 - abs(x - (frame * 7) % width) / 4)
                let detail = ((x ^ y) & 0x1F) * 2
                let value = Swift.max(0, Swift.min(255, gradient + edge + highlight + detail + grain))
                let pixel = row + x * 4
                pixel[0] = UInt8(value)
                pixel[1] = UInt8(Swift.max(0, Swift.min(255, value - 20)))
                pixel[2] = UInt8(Swift.max(0, Swift.min(255, value + 15)))
                pixel[3] = 255
            }
        }
    }
}

// MARK: - Quality

/// VMAF, PSNR and SSIM through ffmpeg, which is the instrument rather than a
/// contestant here.
enum Quality {
    /// VMAF between two video files, normalised to a fixed frame rate first.
    ///
    /// The normalisation is not cosmetic: libvmaf pairs frames by presentation
    /// time, and two containers do not agree on those. Comparing by PTS without
    /// it scored one encoder's 22 Mbps output below another's at the same rate,
    /// because it was comparing frame 40 against frame 41.
    static func vmaf(_ candidate: URL, reference: URL, fps: Int = 30) -> Double? {
        let log = Fixtures.directory.appendingPathComponent("vmaf-\(UUID().uuidString).json")
        let filter = "[0:v]fps=\(fps),setpts=N/\(fps)/TB[d];[1:v]fps=\(fps),setpts=N/\(fps)/TB[r]"
            + ";[d][r]libvmaf=n_threads=8:log_fmt=json:log_path=\(log.path)"
        guard let result = try? shell([
            "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-i", candidate.path, "-i", reference.path, "-lavfi", filter, "-f", "null", "-",
        ]), result.status == 0 else { return nil }
        defer { try? FileManager.default.removeItem(at: log) }

        guard let data = try? Data(contentsOf: log),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pooled = object["pooled_metrics"] as? [String: Any],
              let vmaf = pooled["vmaf"] as? [String: Any],
              let mean = vmaf["mean"] as? Double
        else { return nil }
        return mean
    }

    /// SSIM between two stills, via ffmpeg. Stills have one frame, so the
    /// alignment problem above does not arise.
    static func ssim(_ candidate: URL, reference: URL) -> Double? {
        guard let result = try? shell([
            "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "info",
            "-i", candidate.path, "-i", reference.path, "-lavfi", "ssim", "-f", "null", "-",
        ]) else { return nil }
        guard let range = result.output.range(of: "All:", options: .backwards) else { return nil }
        let tail = result.output[range.upperBound...]
        let number = tail.prefix(while: { $0.isNumber || $0 == "." })
        return Double(number)
    }
}

enum BenchError: Error, CustomStringConvertible {
    case fixture(String)
    case toolFailed(String, Int32)

    var description: String {
        switch self {
        case .fixture(let why): return "fixture: \(why)"
        case .toolFailed(let name, let status): return "\(name) exited \(status)"
        }
    }
}
