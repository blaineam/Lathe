import Foundation
import LatheAudio
import LatheCore
import LatheDoc
import LatheImage
import LatheMeta
import LatheVideo

/// One item in the queue.
@MainActor
@Observable
final class Job: Identifiable {
    enum State: Equatable {
        case waiting
        case running(fraction: Double)
        case done(summary: String)
        case failed(String)
        case skipped(String)
    }

    let id = UUID()
    let source: URL
    var state: State = .waiting
    /// What the file turned out to be, decided by its bytes rather than its
    /// extension — a `.mp4` full of JPEG is read as a JPEG.
    var kind: MediaKind = .unknown
    var outputURL: URL?
    var inputBytes: Int = 0
    var outputBytes: Int = 0

    init(source: URL) {
        self.source = source
        self.inputBytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .flatMap { $0 } ?? 0
    }

    var name: String { source.lastPathComponent }

    /// The size change, once there is one.
    var savings: Double? {
        guard inputBytes > 0, outputBytes > 0 else { return nil }
        return (Double(inputBytes) - Double(outputBytes)) / Double(inputBytes)
    }
}

/// What a file is, for routing. Sniffed, not guessed from the extension.
enum MediaKind: String, Equatable {
    case video, image, audio, document, unknown

    static func of(_ url: URL) -> MediaKind {
        // The extension is a hint for routing only, and a wrong one costs a
        // clear refusal rather than a wrong result — every module sniffs the
        // bytes before it does anything.
        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "m4v", "avi", "mkv", "webm": return .video
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "webp", "avif": return .image
        case "m4a", "mp3", "wav", "aiff", "aif", "flac", "caf": return .audio
        case "pdf", "cbz", "zip": return .document
        default: return .unknown
        }
    }
}

/// What the app does to a file.
enum Operation: String, CaseIterable, Identifiable {
    case compress = "Compress"
    case inspect = "Inspect"
    case stripLocation = "Strip location"

    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .compress:
            return "Re-encode with hardware acceleration where the Mac has it. "
                + "Video becomes HEVC, stills become HEIC, audio becomes AAC."
        case .inspect:
            return "Read what the file is and what it says about itself. Writes nothing."
        case .stripLocation:
            return "Remove GPS coordinates and leave everything else, without re-encoding."
        }
    }
}
