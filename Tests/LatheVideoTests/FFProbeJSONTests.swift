import Foundation
import LatheCore
import LatheFixtures
import Testing

@testable import LatheVideo

/// Tests for the ffprobe compatibility shim.
///
/// These check the JSON's **shape**, by decoding it with `JSONSerialization` and
/// inspecting the runtime types of the values. Decoding into `FFProbeReport`
/// would prove nothing: `Codable` would happily accept a number where ffprobe
/// emits a string, which is exactly the mistake this shim exists to avoid. The
/// only way to assert "duration is a JSON string" is to look at what came out.
@Suite("ffprobe compatibility", .serialized)
struct FFProbeJSONTests {

    private static let size = PixelSize(width: 160, height: 120)

    private func report(from info: MediaInfo) throws -> [String: Any] {
        let data = try info.ffprobeJSON()
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    // MARK: - Shape

    @Test("the top level is a format object and a streams array")
    func topLevelShape() async throws {
        guard let info = await probedFixture() else { return }
        let root = try report(from: info)

        #expect(root["format"] is [String: Any])
        #expect(root["streams"] is [Any])
        let streams = try #require(root["streams"] as? [[String: Any]])
        #expect(streams.count == info.tracks.count)
    }

    /// The assertion the whole shim turns on.
    @Test("durations and bit rates are JSON strings, not JSON numbers")
    func numbersThatMustBeStrings() async throws {
        guard let info = await probedFixture() else { return }
        let root = try report(from: info)
        let format = try #require(root["format"] as? [String: Any])

        // ffprobe emits these as strings. A parser written against ffprobe has a
        // `String` in its model, and a number here is a decode failure inside
        // somebody else's code.
        #expect(format["duration"] is String)
        #expect(format["start_time"] is String)
        #expect(format["size"] is String)
        #expect(format["bit_rate"] is String)

        // `JSONSerialization` hands numbers back as `NSNumber`, and `NSNumber`
        // does not bridge to `String` — so this check cannot pass by accident.
        let duration = try #require(format["duration"] as? String)
        #expect(Double(duration) != nil)
        // ffprobe's own formatting: six decimal places, a dot for the decimal
        // separator whatever the locale says.
        #expect(duration.contains("."))
        #expect(duration.split(separator: ".").last?.count == 6)

        let streams = try #require(root["streams"] as? [[String: Any]])
        for stream in streams {
            #expect(stream["duration"] is String)
            if stream["bit_rate"] != nil { #expect(stream["bit_rate"] is String) }
            if stream["sample_rate"] != nil { #expect(stream["sample_rate"] is String) }
        }
    }

    @Test("dimensions, channel counts and indices are JSON numbers")
    func numbersThatMustStayNumbers() async throws {
        guard let info = await probedFixture() else { return }
        let root = try report(from: info)
        let streams = try #require(root["streams"] as? [[String: Any]])
        let format = try #require(root["format"] as? [String: Any])

        #expect(format["nb_streams"] is NSNumber)
        #expect(!(format["nb_streams"] is String))

        let video = try #require(streams.first { $0["codec_type"] as? String == "video" })
        #expect(video["width"] is NSNumber)
        #expect(video["height"] is NSNumber)
        #expect(video["index"] is NSNumber)
        #expect(video["width"] as? Int == Self.size.width)
        #expect(video["height"] as? Int == Self.size.height)
        #expect(video["coded_width"] as? Int == Self.size.width)

        let audio = try #require(streams.first { $0["codec_type"] as? String == "audio" })
        #expect(audio["channels"] is NSNumber)
        #expect(audio["channels"] as? Int == 1)
        // Audio streams carry no dimensions at all, as in ffprobe.
        #expect(audio["width"] == nil)
        #expect(audio["height"] == nil)
    }

    @Test("codec identification uses ffprobe's vocabulary")
    func codecVocabulary() async throws {
        guard let info = await probedFixture() else { return }
        let root = try report(from: info)
        let streams = try #require(root["streams"] as? [[String: Any]])

        let video = try #require(streams.first { $0["codec_type"] as? String == "video" })
        #expect(video["codec_name"] as? String == "h264")
        // The container's own four-character code survives alongside the name.
        #expect(video["codec_tag_string"] as? String == "avc1")
        #expect(video["r_frame_rate"] as? String == "24/1")

        let audio = try #require(streams.first { $0["codec_type"] as? String == "audio" })
        #expect(audio["codec_name"] as? String == "aac")
        // `codec_tag_string` carries AVFoundation's subtype verbatim, and for
        // audio that is the CoreAudio format ID — so this is `aac ` where
        // ffprobe would print the container tag `mp4a`. Documented on
        // `MediaInfo.ffprobeReport()`: `codec_name` is the field to compare.
        #expect(audio["codec_tag_string"] as? String == "aac ")
    }

    @Test("the report is round-trippable through its own Codable model")
    func roundTrip() async throws {
        guard let info = await probedFixture() else { return }
        let data = try info.ffprobeJSON(prettyPrinted: false)
        let decoded = try JSONDecoder().decode(FFProbeReport.self, from: data)
        #expect(decoded == info.ffprobeReport())
    }

    @Test("the compact and pretty forms carry the same content")
    func prettyPrinting() async throws {
        guard let info = await probedFixture() else { return }
        let pretty = try info.ffprobeJSONString(prettyPrinted: true)
        let compact = try info.ffprobeJSONString(prettyPrinted: false)
        #expect(pretty.contains("\n"))
        #expect(!compact.contains("\n"))
        #expect(try JSONDecoder().decode(FFProbeReport.self, from: Data(pretty.utf8))
                == JSONDecoder().decode(FFProbeReport.self, from: Data(compact.utf8)))
    }

    @Test("a file with no tracks still produces a valid report")
    func emptyAsset() async throws {
        let info = MediaInfo(
            fileName: "nothing.mov", duration: 0, byteCount: 0,
            tracks: [], containerName: "mov,mp4,m4a,3gp,3g2,mj2"
        )
        let root = try report(from: info)
        let format = try #require(root["format"] as? [String: Any])
        #expect(format["nb_streams"] as? Int == 0)
        #expect(format["duration"] as? String == "0.000000")
        #expect((root["streams"] as? [Any])?.isEmpty == true)
    }

    // MARK: - Formatting details

    @Test("seconds are formatted the way ffprobe formats them",
          arguments: [(0.0, "0.000000"), (2.0, "2.000000"), (1.5, "1.500000"),
                      (0.041667, "0.041667"), (3600.25, "3600.250000")])
    func secondsFormatting(_ input: Double, _ expected: String) {
        #expect(MediaInfo.ffprobeSeconds(input) == expected)
    }

    @Test("frame rates come out as rationals",
          arguments: [(24.0, "24/1"), (30.0, "30/1"), (60.0, "60/1"),
                      (29.97003, "30000/1001"), (23.976025, "24000/1001"),
                      (59.940060, "60000/1001")])
    func frameRateRationals(_ input: Double, _ expected: String) {
        #expect(MediaInfo.rationalFrameRate(input) == expected)
    }

    @Test("a non-finite duration does not produce invalid JSON")
    func nonFiniteDuration() {
        #expect(MediaInfo.ffprobeSeconds(.infinity) == "N/A")
        #expect(MediaInfo.ffprobeSeconds(.nan) == "N/A")
        #expect(MediaInfo.rationalFrameRate(0) == "0/0")
    }

    // MARK: - Fixture

    private func probedFixture() async -> MediaInfo? {
        do {
            let movie = try await FixtureLibrary.shared.movie(
                named: "ffprobe-av.mov", size: Self.size, frameRate: 24, seconds: 2,
                audio: .tone(hertz: 440, amplitude: 0.4)
            )
            return try await MediaProbe().probe(url: movie)
        } catch {
            withKnownIssue("could not generate or probe the fixture on this machine: \(error)") {
                Issue.record("fixture generation failed")
            }
            return nil
        }
    }
}
