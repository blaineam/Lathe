import AVFoundation
import Foundation
import LatheAudio
import LatheCore
import LatheDoc
import LatheImage
import LatheMeta
import LatheMP3
import LatheVideo

/// One comparison: Lathe against the tool people would otherwise reach for.
struct Comparison {
    var task: String
    var tool: String
    var latheSeconds: Double
    var toolSeconds: Double
    /// CPU seconds for the same run. Wall clock is what a user waits; CPU is
    /// what the machine spent, and the two diverge sharply once a codec starts
    /// using every core.
    var latheCPU: Double? = nil
    var toolCPU: Double? = nil
    /// Output sizes, where the task produces a file worth sizing.
    var latheBytes: Int?
    var toolBytes: Int?
    /// A quality score for each, where one is meaningful.
    var latheQuality: Double?
    var toolQuality: Double?
    var qualityMetric: String?
    /// What the row is actually showing, in one clause.
    var note: String

    /// Whether both sides landed close enough in quality for their sizes to be
    /// compared. `nil` when the row has no quality measurement at all.
    ///
    /// The tolerances are deliberately tight — one VMAF point, 0.005 SSIM —
    /// because a size claim is the easiest thing in a table like this to get
    /// quietly wrong, and the cost of refusing to make one is only a missing
    /// percentage.
    var isQualityMatched: Bool? {
        guard let lathe = latheQuality, let tool = toolQuality, let metric = qualityMetric else {
            return nil
        }
        switch metric {
        case "VMAF": return abs(lathe - tool) <= 1.0
        case "SSIM": return abs(lathe - tool) <= 0.005
        default: return nil
        }
    }
}

enum Cases {

    // MARK: - Stills

    /// WebP is the sharpest test of the "same library, same output" claim:
    /// Lathe vendors libwebp and `cwebp` IS libwebp. If these two disagree on
    /// size at the same quality, one of them is configured differently.
    static func webP(source: URL) async throws -> Comparison? {
        guard toolExists("cwebp") else { return nil }
        let latheOut = Fixtures.directory.appendingPathComponent("lathe.webp")
        let toolOut = Fixtures.directory.appendingPathComponent("cwebp.webp")

        let lathe = try await bestMeasured {
            _ = try await ImageEncoder().encode(
                source: source, to: latheOut, format: .webp, quality: .quality(0.8)
            )
        }
        let tool = try await bestMeasured(3, inProcess: false) {
            let result = try shell(["cwebp", "-quiet", "-q", "80", source.path, "-o", toolOut.path])
            if result.status != 0 { throw BenchError.toolFailed("cwebp", result.status) }
        }
        let latheTime = lathe.wallSeconds, toolTime = tool.wallSeconds

        return Comparison(
            task: "WebP encode, 1920×1080, q80",
            tool: "cwebp",
            latheSeconds: latheTime, toolSeconds: toolTime,
            latheCPU: lathe.cpuSeconds, toolCPU: tool.cpuSeconds,
            latheBytes: byteCount(latheOut), toolBytes: byteCount(toolOut),
            latheQuality: Quality.ssim(latheOut, reference: source),
            toolQuality: Quality.ssim(toolOut, reference: source),
            qualityMetric: "SSIM",
            note: "Same library. Parity is the expected result and the point."
        )
    }

    /// JPEG through ImageIO against mozjpeg's `cjpeg`, which is a genuinely
    /// better JPEG encoder. A row Lathe is expected to lose on size.
    static func jpeg(source: URL) async throws -> Comparison? {
        guard toolExists("cjpeg") else { return nil }
        let latheOut = Fixtures.directory.appendingPathComponent("lathe.jpg")
        let toolOut = Fixtures.directory.appendingPathComponent("cjpeg.jpg")

        let lathe = try await bestMeasured {
            _ = try await ImageEncoder().encode(
                source: source, to: latheOut, format: .jpeg, quality: .quality(0.8)
            )
        }
        // cjpeg wants a PPM/BMP/TGA, so the PNG is converted first and that
        // conversion is NOT counted against it.
        let ppm = Fixtures.directory.appendingPathComponent("source.ppm")
        _ = try shell(["ffmpeg", "-nostdin", "-y", "-loglevel", "error",
                       "-i", source.path, ppm.path])
        let tool = try await bestMeasured(3, inProcess: false) {
            let result = try shell(["sh", "-c", "cjpeg -quality 80 \(ppm.path) > \(toolOut.path)"])
            if result.status != 0 { throw BenchError.toolFailed("cjpeg", result.status) }
        }
        let latheTime = lathe.wallSeconds, toolTime = tool.wallSeconds

        return Comparison(
            task: "JPEG encode, 1920×1080, q80",
            tool: "cjpeg (mozjpeg)",
            latheSeconds: latheTime, toolSeconds: toolTime,
            latheCPU: lathe.cpuSeconds, toolCPU: tool.cpuSeconds,
            latheBytes: byteCount(latheOut), toolBytes: byteCount(toolOut),
            latheQuality: Quality.ssim(latheOut, reference: source),
            toolQuality: Quality.ssim(toolOut, reference: source),
            qualityMetric: "SSIM",
            note: "ImageIO against a better JPEG encoder. Read the size column, not the clock."
        )
    }

    /// AVIF: ImageIO writes it, `avifenc` drives libaom. Very different cost
    /// models, and the row exists to show that.
    static func avif(source: URL) async throws -> Comparison? {
        guard toolExists("avifenc") else { return nil }
        let latheOut = Fixtures.directory.appendingPathComponent("lathe.avif")
        let toolOut = Fixtures.directory.appendingPathComponent("avifenc.avif")

        let lathe = try await bestMeasured(2) {
            _ = try await ImageEncoder().encode(
                source: source, to: latheOut, format: .avif, quality: .quality(0.8)
            )
        }
        let tool = try await bestMeasured(2, inProcess: false) {
            let result = try shell(["avifenc", "-q", "80", "--speed", "6",
                                    source.path, toolOut.path])
            if result.status != 0 { throw BenchError.toolFailed("avifenc", result.status) }
        }
        let latheTime = lathe.wallSeconds, toolTime = tool.wallSeconds

        return Comparison(
            task: "AVIF encode, 1920×1080, q80",
            tool: "avifenc (libaom)",
            latheSeconds: latheTime, toolSeconds: toolTime,
            latheCPU: lathe.cpuSeconds, toolCPU: tool.cpuSeconds,
            latheBytes: byteCount(latheOut), toolBytes: byteCount(toolOut),
            latheQuality: Quality.ssim(latheOut, reference: source),
            toolQuality: Quality.ssim(toolOut, reference: source),
            qualityMetric: "SSIM",
            note: "Apple's AVIF encoder against libaom's."
        )
    }

    // MARK: - Video

    /// The headline row. Lathe's VideoToolbox HEVC against ffmpeg driving x265
    /// in software — the comparison a user makes when they reach for ffmpeg.
    static func hevcSoftware(source: URL) async throws -> Comparison? {
        guard toolExists("ffmpeg") else { return nil }
        let latheOut = Fixtures.directory.appendingPathComponent("lathe-hevc.mov")
        let toolOut = Fixtures.directory.appendingPathComponent("x265.mp4")

        let lathe = try await bestMeasured(2) {
            _ = try await VideoTranscoder().transcode(
                source: source, to: latheOut, codec: .hevc, quality: .quality(0.65)
            )
        }
        let tool = try await bestMeasured(1, inProcess: false) {
            let result = try shell([
                "ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", source.path,
                "-c:v", "libx265", "-preset", "medium", "-crf", "26",
                "-tag:v", "hvc1", toolOut.path,
            ])
            if result.status != 0 { throw BenchError.toolFailed("ffmpeg/libx265", result.status) }
        }
        let latheTime = lathe.wallSeconds, toolTime = tool.wallSeconds

        return Comparison(
            task: "HEVC transcode, 1080p30, 5 s",
            tool: "ffmpeg −c:v libx265 −preset medium",
            latheSeconds: latheTime, toolSeconds: toolTime,
            latheCPU: lathe.cpuSeconds, toolCPU: tool.cpuSeconds,
            latheBytes: byteCount(latheOut), toolBytes: byteCount(toolOut),
            latheQuality: Quality.vmaf(latheOut, reference: source),
            toolQuality: Quality.vmaf(toolOut, reference: source),
            qualityMetric: "VMAF",
            note: "Hardware against software. The CPU column is the real gap; x265 wins on bits."
        )
    }

    /// The same job with ffmpeg using the *same* hardware encoder, which
    /// separates "Lathe is fast" from "the Mac is fast".
    static func hevcHardware(source: URL) async throws -> Comparison? {
        guard toolExists("ffmpeg") else { return nil }
        let latheOut = Fixtures.directory.appendingPathComponent("lathe-hevc.mov")
        let toolOut = Fixtures.directory.appendingPathComponent("vt-hevc.mp4")

        let lathe = try await bestMeasured(2) {
            _ = try await VideoTranscoder().transcode(
                source: source, to: latheOut, codec: .hevc, quality: .quality(0.65)
            )
        }
        let tool = try await bestMeasured(2, inProcess: false) {
            let result = try shell([
                "ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", source.path,
                "-c:v", "hevc_videotoolbox", "-q:v", "55", "-tag:v", "hvc1", toolOut.path,
            ])
            if result.status != 0 {
                throw BenchError.toolFailed("ffmpeg/hevc_videotoolbox", result.status)
            }
        }
        let latheTime = lathe.wallSeconds, toolTime = tool.wallSeconds

        return Comparison(
            task: "HEVC transcode, 1080p30, 5 s",
            tool: "ffmpeg −c:v hevc_videotoolbox",
            latheSeconds: latheTime, toolSeconds: toolTime,
            latheCPU: lathe.cpuSeconds, toolCPU: tool.cpuSeconds,
            latheBytes: byteCount(latheOut), toolBytes: byteCount(toolOut),
            latheQuality: Quality.vmaf(latheOut, reference: source),
            toolQuality: Quality.vmaf(toolOut, reference: source),
            qualityMetric: "VMAF",
            note: "Same silicon both sides. What is left is process launch and muxing."
        )
    }

    /// **AV1 and VP9 through ffmpeg, against the HEVC Lathe actually ships.**
    ///
    /// This is the choice a Lathe user has today, stated honestly: Lathe gives
    /// you hardware HEVC, and if you want AV1 or VP9 you reach for ffmpeg. The
    /// row exists to show what that costs rather than to pretend Lathe has an
    /// answer it does not — the AV1 and WebM encoders are spikes in separate
    /// repositories and **do not ship in Lathe**.
    static func modernCodec(
        source: URL, name: String, encoder: String, arguments: [String], suffix: String
    ) async throws -> Comparison? {
        guard toolExists("ffmpeg") else { return nil }
        let latheOut = Fixtures.directory.appendingPathComponent("lathe-hevc.mov")
        let toolOut = Fixtures.directory.appendingPathComponent("\(encoder).\(suffix)")

        let lathe = try await bestMeasured(2) {
            _ = try await VideoTranscoder().transcode(
                source: source, to: latheOut, codec: .hevc, quality: .quality(0.65)
            )
        }
        let tool = try await bestMeasured(1, inProcess: false) {
            let result = try shell([
                "ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", source.path,
                "-c:v", encoder,
            ] + arguments + [toolOut.path])
            if result.status != 0 { throw BenchError.toolFailed("ffmpeg/\(encoder)", result.status) }
        }

        return Comparison(
            task: "1080p30 5 s → \(name)",
            tool: "ffmpeg −c:v \(encoder)",
            latheSeconds: lathe.wallSeconds, toolSeconds: tool.wallSeconds,
            latheCPU: lathe.cpuSeconds, toolCPU: tool.cpuSeconds,
            latheBytes: byteCount(latheOut), toolBytes: byteCount(toolOut),
            latheQuality: Quality.vmaf(latheOut, reference: source),
            toolQuality: Quality.vmaf(toolOut, reference: source),
            qualityMetric: "VMAF",
            note: "Lathe ships HEVC, not \(name). This is what reaching for \(name) costs today."
        )
    }

    // MARK: - Audio

    static func aac(source: URL) async throws -> Comparison? {
        guard toolExists("ffmpeg") else { return nil }
        let latheOut = Fixtures.directory.appendingPathComponent("lathe.m4a")
        let toolOut = Fixtures.directory.appendingPathComponent("ffmpeg.m4a")

        let lathe = try await bestMeasured {
            _ = try await AudioTranscoder().transcode(
                source: source, to: latheOut, codec: .aac, quality: .quality(0.6)
            )
        }
        let tool = try await bestMeasured(3, inProcess: false) {
            let result = try shell([
                "ffmpeg", "-nostdin", "-y", "-loglevel", "error", "-i", source.path,
                "-c:a", "aac", "-b:a", "128k", toolOut.path,
            ])
            if result.status != 0 { throw BenchError.toolFailed("ffmpeg/aac", result.status) }
        }
        let latheTime = lathe.wallSeconds, toolTime = tool.wallSeconds

        return Comparison(
            task: "AAC encode, 10 s stereo 44.1 kHz",
            tool: "ffmpeg −c:a aac",
            latheSeconds: latheTime, toolSeconds: toolTime,
            latheCPU: lathe.cpuSeconds, toolCPU: tool.cpuSeconds,
            latheBytes: byteCount(latheOut), toolBytes: byteCount(toolOut),
            latheQuality: nil, toolQuality: nil, qualityMetric: nil,
            note: "AudioToolbox against ffmpeg's built-in AAC. Not rate-matched, so read the clock rather than the bytes."
        )
    }

    static func mp3(source: URL) async throws -> Comparison? {
        guard toolExists("lame") else { return nil }
        let latheOut = Fixtures.directory.appendingPathComponent("lathe.mp3")
        let toolOut = Fixtures.directory.appendingPathComponent("lame.mp3")

        let lathe = try await bestMeasured {
            _ = try await MP3Encoder().encode(
                source: source, to: latheOut, quality: .quality(0.6)
            )
        }
        let tool = try await bestMeasured(3, inProcess: false) {
            let result = try shell(["lame", "--quiet", "-V", "4", source.path, toolOut.path])
            if result.status != 0 { throw BenchError.toolFailed("lame", result.status) }
        }
        let latheTime = lathe.wallSeconds, toolTime = tool.wallSeconds

        return Comparison(
            task: "MP3 encode, 10 s stereo 44.1 kHz",
            tool: "lame −V4",
            latheSeconds: latheTime, toolSeconds: toolTime,
            latheCPU: lathe.cpuSeconds, toolCPU: tool.cpuSeconds,
            latheBytes: byteCount(latheOut), toolBytes: byteCount(toolOut),
            latheQuality: nil, toolQuality: nil, qualityMetric: nil,
            note: "Same encoder — Lathe vendors LAME — but `-V4` and quality(0.6) are not the same target, so the byte counts are not comparable."
        )
    }

    // MARK: - Reading

    /// Probing is where an in-process library should win outright, because the
    /// work is small and the process launch is not.
    static func probe(source: URL) async throws -> Comparison? {
        guard toolExists("ffprobe") else { return nil }

        let lathe = try await bestMeasured(5) {
            _ = try await MediaProbe().probe(url: source)
        }
        let tool = try await bestMeasured(5, inProcess: false) {
            let result = try shell([
                "ffprobe", "-v", "quiet", "-print_format", "json",
                "-show_format", "-show_streams", source.path,
            ])
            if result.status != 0 { throw BenchError.toolFailed("ffprobe", result.status) }
        }
        let latheTime = lathe.wallSeconds, toolTime = tool.wallSeconds

        return Comparison(
            task: "Probe a 1080p file (duration, tracks, codecs)",
            tool: "ffprobe",
            latheSeconds: latheTime, toolSeconds: toolTime,
            latheCPU: lathe.cpuSeconds, toolCPU: tool.cpuSeconds,
            latheBytes: nil, toolBytes: nil,
            latheQuality: nil, toolQuality: nil, qualityMetric: nil,
            note: "Small work, so the process launch dominates. This is the in-process case."
        )
    }

    /// Metadata injection: the guarantee is that neither re-encodes, and the
    /// difference is a process launch and a library.
    static func metadataWrite(source: URL) async throws -> Comparison? {
        guard toolExists("exiftool") else { return nil }
        let latheOut = Fixtures.directory.appendingPathComponent("lathe-tagged.jpg")
        let toolOut = Fixtures.directory.appendingPathComponent("exiftool-tagged.jpg")

        // A JPEG, because that is what both sides can write metadata into.
        let jpeg = Fixtures.directory.appendingPathComponent("meta-source.jpg")
        if !FileManager.default.fileExists(atPath: jpeg.path) {
            _ = try await ImageEncoder().encode(
                source: source, to: jpeg, format: .jpeg, quality: .quality(0.9)
            )
        }

        let lathe = try await bestMeasured(5) {
            var meta = MediaMetadata()
            meta.title = "A Benchmarked Title"
            meta.creators = ["A Photographer"]
            _ = try await MetadataWriter().write(meta, to: jpeg, writingTo: latheOut)
        }
        let tool = try await bestMeasured(5, inProcess: false) {
            try? FileManager.default.removeItem(at: toolOut)
            try FileManager.default.copyItem(at: jpeg, to: toolOut)
            let result = try shell([
                "exiftool", "-overwrite_original", "-q",
                "-Title=A Benchmarked Title", "-Artist=A Photographer", toolOut.path,
            ])
            if result.status != 0 { throw BenchError.toolFailed("exiftool", result.status) }
        }
        let latheTime = lathe.wallSeconds, toolTime = tool.wallSeconds

        return Comparison(
            task: "Write title and author into a JPEG",
            tool: "exiftool",
            latheSeconds: latheTime, toolSeconds: toolTime,
            latheCPU: lathe.cpuSeconds, toolCPU: tool.cpuSeconds,
            latheBytes: byteCount(latheOut), toolBytes: byteCount(toolOut),
            latheQuality: nil, toolQuality: nil, qualityMetric: nil,
            note: "Neither re-encodes. exiftool also pays a Perl interpreter's start-up."
        )
    }
}
