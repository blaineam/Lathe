import Foundation
import LatheCore
import Vision

/// What this system's Vision can actually recognise — asked, not assumed.
///
/// The same rule `EncodeSupport` is built around, applied to OCR: **ask the
/// system, never the calendar.** There is no `#available` in this file and there
/// is not meant to be one.
///
/// Two things make the probe worth having rather than hard-coding a language
/// list:
///
/// - **The supported language set is not a constant.** It differs by
///   recognition level (the fast path supports fewer languages than the accurate
///   one), by request revision, by OS, and on iOS by which language assets the
///   device has. A list compiled from documentation is wrong on somebody's
///   device the week it is written.
/// - **An unsupported language is a hard failure, not a degradation.** Handing
///   `VNRecognizeTextRequest` a `recognitionLanguages` array containing one
///   language it does not know makes `perform` throw, and the whole document
///   fails because of one optimistic entry in a preferences array. Resolving the
///   request against what the system reports turns that into "we OCR'd it in the
///   languages this device has", which is what the caller wanted.
///
/// Results are cached per level for the life of the process: the probe builds a
/// request and asks it, which is cheap but not free, and the answer cannot
/// change without the process restarting.
public struct VisionTextSupport: Sendable {

    public static let shared = VisionTextSupport()

    private let cache = Cache()

    private init() {}

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var languages: [Int: [String]] = [:]

        func languages(for key: Int, build: () -> [String]) -> [String] {
            lock.lock()
            if let cached = languages[key] { lock.unlock(); return cached }
            lock.unlock()
            let value = build()
            lock.lock()
            languages[key] = value
            lock.unlock()
            return value
        }
    }

    // MARK: - Probing

    /// The languages this system will recognise at a given accuracy, in Vision's
    /// own preference order.
    ///
    /// Empty if the probe itself failed, which is a real outcome on a device
    /// whose OCR assets have not been downloaded yet — and one that must not be
    /// confused with "no languages are any good", so callers fall back to
    /// letting Vision pick rather than refusing the document.
    public func supportedLanguages(accuracy: TextRecognitionAccuracy) -> [String] {
        cache.languages(for: accuracy.visionLevel.rawValue) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = accuracy.visionLevel
            do {
                return try request.supportedRecognitionLanguages()
            } catch {
                LatheLog.doc.debug(
                    """
                    Vision would not report its supported recognition languages \
                    (\(String(describing: error), privacy: .public)); falling back to its own \
                    default language selection
                    """
                )
                return []
            }
        }
    }

    /// The request revision Vision will use. Reported in
    /// ``PDFTextLayerResult/recognitionRevision`` so a text layer's provenance is
    /// recoverable from the result rather than from the OS version.
    public var currentRevision: Int { VNRecognizeTextRequest.currentRevision }

    /// Every revision this system offers, newest last.
    public var supportedRevisions: [Int] { VNRecognizeTextRequest.supportedRevisions.sorted() }

    // MARK: - Resolving a request

    /// Narrows a caller's wish list to what this system will actually accept.
    ///
    /// - Returns: the requested languages that are supported, in the caller's
    ///   order; or `[]` meaning "let Vision choose", which is what an empty
    ///   request, an unrecognised wish list, or a failed probe all resolve to.
    ///   Never returns a language the system did not name.
    public func resolve(
        languages requested: [String],
        accuracy: TextRecognitionAccuracy
    ) -> [String] {
        guard !requested.isEmpty else { return [] }
        let supported = supportedLanguages(accuracy: accuracy)
        guard !supported.isEmpty else { return [] }

        // Matched on the language subtag as well as the whole identifier, so a
        // caller asking for "en" gets "en-US" rather than nothing — the BCP-47
        // spelling Vision reports has changed between releases, and a caller
        // should not have to track it.
        var resolved: [String] = []
        for wanted in requested {
            if let exact = supported.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) {
                resolved.append(exact)
                continue
            }
            let prefix = wanted.split(separator: "-").first.map(String.init) ?? wanted
            if let loose = supported.first(where: {
                $0.split(separator: "-").first.map(String.init)?
                    .caseInsensitiveCompare(prefix) == .orderedSame
            }) {
                resolved.append(loose)
            }
        }

        if resolved.isEmpty {
            LatheLog.doc.debug(
                """
                none of the requested OCR languages are supported here; letting Vision choose \
                (this system offers \(supported.count, privacy: .public))
                """
            )
        }
        return resolved
    }

    /// A one-line summary for a bug report, in the shape of
    /// `Lathe.capabilityReport`.
    public var diagnosticReport: String {
        let accurate = supportedLanguages(accuracy: .accurate)
        let fast = supportedLanguages(accuracy: .fast)
        return """
            Vision text recognition
              revision:  \(currentRevision) (available: \(supportedRevisions.map(String.init).joined(separator: ", ")))
              accurate:  \(accurate.isEmpty ? "unreported" : accurate.joined(separator: " "))
              fast:      \(fast.isEmpty ? "unreported" : fast.joined(separator: " "))
            """
    }
}

/// How hard Vision should work, per page.
public enum TextRecognitionAccuracy: Sendable, Equatable, CaseIterable {
    /// Neural, slower, far better on anything that is not clean print. The
    /// default, because a text layer is written once and searched forever.
    case accurate
    /// The fast path. Fewer languages, and noticeably worse on scans.
    case fast

    var visionLevel: VNRequestTextRecognitionLevel {
        switch self {
        case .accurate: .accurate
        case .fast: .fast
        }
    }
}
