import Foundation
import Testing

@testable import LatheVideo

/// Choosing which frames to take out of a video.
///
/// The timestamp arithmetic is tested on its own because it is where the
/// decisions are — extracting is then the same single-frame path already
/// covered, run in a loop.
@Suite("Frame selection")
struct FrameSequenceTests {

    @Test("an interval walks the whole thing")
    func everySeconds() throws {
        let times = try FrameExtractor.timestamps(for: .everySeconds(2), duration: 9)
        #expect(times == [0, 2, 4, 6, 8])
    }

    @Test("an interval longer than the file still gives one frame")
    func intervalLongerThanDuration() throws {
        let times = try FrameExtractor.timestamps(for: .everySeconds(60), duration: 9)
        #expect(times == [0])
    }

    /// The first and last frames of a video are very often black, so a count
    /// samples the middle of each slice rather than running end to end. A
    /// contact sheet that opens and closes on black is the usual symptom of
    /// getting this wrong.
    @Test("a count avoids the very start and the very end")
    func countAvoidsTheEdges() throws {
        let times = try FrameExtractor.timestamps(for: .count(4), duration: 100)
        #expect(times == [12.5, 37.5, 62.5, 87.5])
        #expect(times.first! > 0)
        #expect(times.last! < 100)
    }

    @Test("one frame is taken from the middle")
    func singleFrameIsTheMiddle() throws {
        #expect(try FrameExtractor.timestamps(for: .count(1), duration: 60) == [30])
    }

    /// A caller that guessed the duration should get the last frame, not an
    /// error.
    @Test("explicit timestamps are clamped into the file")
    func clampsExplicitTimes() throws {
        let times = try FrameExtractor.timestamps(
            for: .atSeconds([-5, 3, 999]), duration: 10)
        #expect(times[0] == 0)
        #expect(times[1] == 3)
        #expect(times[2] < 10)
        #expect(times[2] > 9.9)
    }

    @Test("a nonsensical selection is refused rather than guessed at")
    func refusesNonsense() {
        #expect(throws: (any Error).self) {
            try FrameExtractor.timestamps(for: .everySeconds(0), duration: 10)
        }
        #expect(throws: (any Error).self) {
            try FrameExtractor.timestamps(for: .count(0), duration: 10)
        }
    }
}
