import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import LatheCore

/// Synthetic media, generated at run time.
///
/// **No binary media is committed to this repository.** Every clip the test
/// suite needs is written here by `AVAssetWriter` and `AVAudioFile` into a
/// temporary directory, which buys three things worth the code:
///
/// - The fixtures' properties are *known* rather than measured from a file
///   somebody once made. A test can assert that a clip is 2.0 seconds at 24 fps
///   because these lines put it there.
/// - There is nothing whose provenance, licence or copyright has to be
///   explained in an open repository.
/// - A clip that cannot be generated on a given machine fails loudly at
///   generation, where the reason is legible, instead of producing a confusing
///   assertion failure later.
///
/// Every entry point throws ``FixtureError`` on failure so a test can convert it
/// into a skip rather than an unexplained red.
public enum FixtureError: Error, CustomStringConvertible {
    case writerUnavailable(String)
    case writeFailed(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case let .writerUnavailable(detail): "no media writer available: \(detail)"
        case let .writeFailed(detail): "fixture could not be written: \(detail)"
        case let .unsupported(detail): "fixture is unsupported here: \(detail)"
        }
    }
}

/// What to put in a fixture's audio track.
public enum FixtureAudio: Sendable, Equatable, Hashable {
    /// No audio track at all.
    case none
    /// A track of samples that are all exactly zero.
    case silence
    /// A continuous sine tone.
    case tone(hertz: Double, amplitude: Float)
    /// A short tone surrounded by silence — the sparse-audio case that breaks
    /// whole-file mean volume.
    case sparseTone(hertz: Double, amplitude: Float, onsetSeconds: Double, lengthSeconds: Double)
    /// Exactly one non-zero sample. A splice, a decoder artefact — something
    /// with a large peak and almost no energy.
    case click(amplitude: Float, atSeconds: Double)

    var isPresent: Bool { self != .none }
}

/// Builds, caches and cleans up the suite's fixtures.
///
/// An actor because two test targets generate overlapping fixtures and each
/// clip should be encoded once per process, not once per test.
public actor FixtureLibrary {

    public static let shared = FixtureLibrary()

    /// Sample rate used by every generated audio track.
    public static let sampleRate: Double = 44_100

    private let root: URL
    private var built: [String: URL] = [:]

    private init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-fixtures-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// A path inside the fixture directory that no fixture occupies — for
    /// thumbnails and other test output.
    public func scratchURL(named name: String) -> URL {
        root.appendingPathComponent(name)
    }

    private func cached(_ key: String, _ build: (URL) async throws -> Void) async throws -> URL {
        if let existing = built[key] { return existing }
        let url = root.appendingPathComponent(key)
        try? FileManager.default.removeItem(at: url)
        try await build(url)
        built[key] = url
        return url
    }

    // MARK: - Movies

    /// A QuickTime movie of a solid colour (or a two-colour split), H.264, at a
    /// known size, frame rate and duration.
    ///
    /// - Parameters:
    ///   - size: coded pixel dimensions.
    ///   - frameRate: frames per second; the clip carries exactly
    ///     `frameRate × seconds` frames.
    ///   - rightHalf: when given, the right half of every frame uses this colour
    ///     instead, so a grayscale reduction has something to reduce. A solid
    ///     frame cannot distinguish a working luminance conversion from one that
    ///     returns a constant.
    ///   - noise: fill every frame with deterministic pseudo-random pixels
    ///     instead. A flat clip is the wrong fixture for anything that asserts
    ///     about *size*: it compresses to nearly nothing at every quality, so a
    ///     quality knob that does nothing still passes.
    ///   - rotationDegrees: written into the track's display matrix, so the clip
    ///     is stored on one set of axes and displayed on another.
    ///   - creationDate: a QuickTime creation date, for metadata policy tests.
    ///   - location: an ISO 6709 location string, likewise.
    public func movie(
        named name: String,
        size: PixelSize = PixelSize(width: 160, height: 120),
        frameRate: Int = 24,
        seconds: Double = 2,
        colour: FixtureColour = .init(red: 32, green: 32, blue: 32),
        rightHalf: FixtureColour? = nil,
        audio: FixtureAudio = .none,
        noise: Bool = false,
        rotationDegrees: Int = 0,
        creationDate: Date? = nil,
        location: String? = nil
    ) async throws -> URL {
        try await cached(name) { url in
            try await MovieWriter(
                url: url, size: size, frameRate: frameRate, seconds: seconds,
                left: colour, right: rightHalf ?? colour, audio: audio,
                noise: noise, rotationDegrees: rotationDegrees,
                creationDate: creationDate, location: location
            ).write()
        }
    }

    // MARK: - Audio-only

    /// A 16-bit PCM WAV file.
    ///
    /// PCM rather than AAC wherever the *sample values* matter: a lossy codec
    /// does not round-trip digital silence to exactly zero, and a test for
    /// "every sample is zero" written against an AAC fixture is a test of the
    /// encoder's noise floor.
    public func wav(
        named name: String,
        seconds: Double,
        audio: FixtureAudio
    ) async throws -> URL {
        try await cached(name) { url in
            try Self.writeWAV(to: url, seconds: seconds, audio: audio)
        }
    }

    /// A valid but empty WAV: a header, no sample frames, zero duration.
    public func emptyWAV(named name: String) async throws -> URL {
        try await cached(name) { url in
            try Self.writeWAV(to: url, seconds: 0, audio: .silence)
        }
    }

    // MARK: - Non-media

    /// A text file with a media extension. Not media by any reading.
    public func notMedia(named name: String) async throws -> URL {
        try await cached(name) { url in
            let text = "this is not a media file, whatever the extension says\n"
            try text.data(using: .utf8)!.write(to: url)
        }
    }

    /// A small PNG, for the "an image is not a video, but is it an asset?"
    /// question.
    public func stillImage(named name: String) async throws -> URL {
        try await cached(name) { url in
            try Self.writePNG(to: url, size: PixelSize(width: 48, height: 32))
        }
    }

    /// Removes everything generated. Optional — the directory is under the
    /// system temporary directory either way.
    public func removeAll() {
        try? FileManager.default.removeItem(at: root)
        built.removeAll()
    }
}

/// An 8-bit RGB colour for a generated frame.
public struct FixtureColour: Sendable, Equatable, Hashable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = FixtureColour(red: 0, green: 0, blue: 0)
    public static let white = FixtureColour(red: 255, green: 255, blue: 255)
}

// MARK: - Sample synthesis

extension FixtureLibrary {

    /// Mono Float32 samples for a waveform, at ``sampleRate``.
    public static func samples(for audio: FixtureAudio, seconds: Double) -> [Float] {
        let count = Int((seconds * sampleRate).rounded())
        guard count > 0 else { return [] }
        var values = [Float](repeating: 0, count: count)

        switch audio {
        case .none, .silence:
            break

        case let .tone(hertz, amplitude):
            for index in 0..<count {
                values[index] = amplitude * Float(sin(2 * .pi * hertz * Double(index) / sampleRate))
            }

        case let .sparseTone(hertz, amplitude, onsetSeconds, lengthSeconds):
            let start = max(0, min(count, Int((onsetSeconds * sampleRate).rounded())))
            let end = max(start, min(count, start + Int((lengthSeconds * sampleRate).rounded())))
            for index in start..<end {
                values[index] = amplitude * Float(sin(2 * .pi * hertz * Double(index) / sampleRate))
            }

        case let .click(amplitude, atSeconds):
            let index = max(0, min(count - 1, Int((atSeconds * sampleRate).rounded())))
            values[index] = amplitude
        }
        return values
    }

    /// The mean level these samples *should* measure, by construction.
    ///
    /// Lets a test assert against arithmetic rather than against whatever the
    /// implementation happened to return the first time it was run.
    public static func expectedMeanVolumeDB(for audio: FixtureAudio, seconds: Double) -> Double? {
        let values = samples(for: audio, seconds: seconds)
        guard !values.isEmpty else { return nil }
        let sumOfSquares = values.reduce(into: 0.0) { $0 += Double($1) * Double($1) }
        guard sumOfSquares > 0 else { return nil }
        return 10 * log10(sumOfSquares / Double(values.count))
    }
}

// MARK: - WAV

extension FixtureLibrary {

    static func writeWAV(to url: URL, seconds: Double, audio: FixtureAudio) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            throw FixtureError.writerUnavailable("AVAudioFile for WAV: \(error.localizedDescription)")
        }

        let values = samples(for: audio, seconds: seconds)
        guard !values.isEmpty else { return }   // header only: a zero-duration asset

        // `AVAudioFile` takes buffers in its *processing* format — deinterleaved
        // Float32 — and converts to the file's 16-bit format on write.
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(values.count)
        ), let channel = buffer.floatChannelData?[0] else {
            throw FixtureError.writeFailed("could not allocate a PCM buffer")
        }
        buffer.frameLength = AVAudioFrameCount(values.count)
        values.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: values.count)
        }

        do {
            try file.write(from: buffer)
        } catch {
            throw FixtureError.writeFailed("WAV write: \(error.localizedDescription)")
        }
    }
}

// MARK: - PNG

extension FixtureLibrary {

    static func writePNG(to url: URL, size: PixelSize) throws {
        let bytesPerRow = size.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * size.height)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 255      // B
            pixels[index + 1] = 128  // G
            pixels[index + 2] = 64   // R
            pixels[index + 3] = 255  // A
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: size.width, height: size.height,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue
                  ),
                  provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                  url as CFURL, "public.png" as CFString, 1, nil
              )
        else {
            throw FixtureError.writeFailed("could not build a PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.writeFailed("could not finalise a PNG")
        }
    }
}
