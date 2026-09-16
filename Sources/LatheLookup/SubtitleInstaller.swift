import Foundation
import LatheCore
import LatheMeta

/// `SubtitleFormat` moved to LatheMeta with the parser that reads it. The alias
/// keeps `import LatheLookup` alone enough to name it, as it was before.
public typealias SubtitleFormat = LatheMeta.SubtitleFormat

#if canImport(AVFoundation)

/// Finds subtitles for a film on OpenSubtitles, downloads the chosen ones, and
/// writes them into the file.
///
/// ## Whose credentials
///
/// The caller's, through the ``OpenSubtitlesProvider`` it is given — an API key
/// from the user and a User-Agent registered for the application. Nothing here
/// has a key of its own, for the reasons ``MetadataProvider`` gives.
///
/// ## Why search and install are separate calls
///
/// A download is metered per key per day, and the limit is low enough that a
/// user can reach it on one evening's films. So ``candidates(for:languages:imdbID:)``
/// costs nothing and returns everything, ranked; ``install(_:into:writingTo:existing:)``
/// downloads exactly what it is handed; and ``installBest(into:writingTo:languages:imdbID:existing:)``,
/// the one-call version, downloads one file per language and never more.
public struct SubtitleInstaller: Sendable {

    public let provider: OpenSubtitlesProvider
    private let muxer = SubtitleMuxer()

    public init(provider: OpenSubtitlesProvider) {
        self.provider = provider
    }

    // MARK: - Searching

    /// Subtitles for `file`, best first, searched by the title and episode its
    /// name implies — or by `imdbID`, which is better when it is known.
    public func candidates(
        for file: URL, languages: [String] = ["en"], imdbID: String? = nil
    ) async throws -> [SubtitleCandidate] {
        let lookup = MediaTitleParser().query(forFilename: file)
        let query = SubtitleQuery(lookup, imdbID: imdbID, languages: languages)
        let found = try await provider.search(query)
        return Self.rank(found, forFile: file)
    }

    /// Orders candidates the way a person choosing would.
    ///
    /// 1. **Not machine-translated.** The API flags these, and they are the
    ///    most common reason a download is wasted.
    /// 2. **Timed against this release.** A subtitle made for the same rip is
    ///    in sync; one made for a different cut drifts by seconds within
    ///    minutes. The file's own name is the best evidence of its release.
    /// 3. **Most downloaded**, which is a crowd's verdict on everything else.
    static func rank(_ candidates: [SubtitleCandidate], forFile file: URL) -> [SubtitleCandidate] {
        let fileRelease = normalisedRelease(file.deletingPathExtension().lastPathComponent)
        func releaseMatches(_ candidate: SubtitleCandidate) -> Bool {
            guard !fileRelease.isEmpty else { return false }
            let names = [candidate.releaseName, (candidate.fileName as NSString).deletingPathExtension]
                .compactMap { $0 }.map(normalisedRelease)
            return names.contains { name in
                if name == fileRelease { return true }
                // Containment only between names of comparable length: a
                // subtitle called "b.srt" is not a match for every release with
                // a "b" in it.
                let (short, long) = name.count < fileRelease.count ? (name, fileRelease) : (fileRelease, name)
                return short.count >= max(8, long.count / 2) && long.contains(short)
            }
        }
        return candidates.enumerated().sorted { lhs, rhs in
            let (a, b) = (lhs.element, rhs.element)
            if a.isMachineTranslated != b.isMachineTranslated { return !a.isMachineTranslated }
            let (am, bm) = (releaseMatches(a), releaseMatches(b))
            if am != bm { return am }
            let (ad, bd) = (a.downloadCount ?? 0, b.downloadCount ?? 0)
            if ad != bd { return ad > bd }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func normalisedRelease(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    // MARK: - Installing

    /// Downloads `candidates` — one metered download each — and writes them
    /// into `file` as subtitle tracks, in one pass over the film.
    ///
    /// Downloads are parsed with ``SubtitleParser/Recovery/skipInvalidCues``:
    /// a community subtitle with one mistimed line is still worth having, and
    /// what was skipped is reported rather than hidden.
    public func install(
        _ candidates: [SubtitleCandidate],
        into file: URL,
        writingTo destination: URL,
        existing: ExistingSubtitlePolicy = .replaceSameLanguage
    ) async throws -> SubtitleInstallResult {
        guard !candidates.isEmpty else {
            throw LatheError.invalidConfiguration(reason: "no subtitles were chosen to install")
        }
        var tracks: [SubtitleTrackSource] = []
        var issues: [[SubtitleIssue]] = []
        var remaining: Int?
        for candidate in candidates {
            let document = try await provider.download(candidate)
            remaining = document.remainingDownloads ?? remaining
            let parsed = try SubtitleParser.parse(
                document.data,
                format: document.format == .unknown ? nil : document.format,
                recovery: .skipInvalidCues
            )
            tracks.append(SubtitleTrackSource(
                cues: parsed.cues,
                language: Self.trackLanguage(candidate.language),
                isHearingImpaired: candidate.isHearingImpaired
            ))
            issues.append(parsed.issues)
        }

        let injection = try await muxer.inject(tracks, into: file, writingTo: destination, existing: existing)
        return SubtitleInstallResult(
            injection: injection, installed: candidates,
            skippedCues: issues, remainingDownloads: remaining
        )
    }

    /// Searches, picks the best candidate for each language, and installs
    /// them: one search request and one download per language found.
    ///
    /// - Throws: ``LookupError`` from the provider, ``SubtitleError`` from
    ///   parsing or writing, and ``SubtitleInstallError/nothingFound(languages:)``
    ///   when no language had a usable candidate.
    public func installBest(
        into file: URL,
        writingTo destination: URL,
        languages: [String] = ["en"],
        imdbID: String? = nil,
        existing: ExistingSubtitlePolicy = .replaceSameLanguage
    ) async throws -> SubtitleInstallResult {
        let ranked = try await candidates(for: file, languages: languages, imdbID: imdbID)
        var chosen: [SubtitleCandidate] = []
        for language in languages {
            let wanted = language.lowercased()
            if let best = ranked.first(where: { Self.sameLanguage($0.language, wanted) }),
               !chosen.contains(best) {
                chosen.append(best)
            }
        }
        guard !chosen.isEmpty else { throw SubtitleInstallError.nothingFound(languages: languages) }
        return try await install(chosen, into: file, writingTo: destination, existing: existing)
    }

    /// The service's language code, or `und` when it is not a well-formed tag:
    /// a label the track header cannot hold is not worth failing an install
    /// that has already spent a download.
    static func trackLanguage(_ code: String) -> String {
        (try? SubtitleLanguage(code)) == nil ? "und" : code
    }

    private static func sameLanguage(_ candidate: String, _ wanted: String) -> Bool {
        let a = candidate.lowercased()
        return a == wanted || a.hasPrefix(wanted + "-") || wanted.hasPrefix(a + "-")
    }
}

/// What an install did.
public struct SubtitleInstallResult: Sendable, Equatable {
    public var injection: SubtitleInjectionResult
    /// What was downloaded, in track order.
    public var installed: [SubtitleCandidate]
    /// Per installed track: cues the parser skipped, and why.
    public var skippedCues: [[SubtitleIssue]]
    /// Downloads left on the user's key today, when the API said.
    public var remainingDownloads: Int?
}

public enum SubtitleInstallError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The search came back with nothing in any wanted language.
    case nothingFound(languages: [String])

    public var description: String {
        switch self {
        case let .nothingFound(languages):
            return "no subtitles were found in \(languages.joined(separator: ", "))"
        }
    }

    public var errorDescription: String? { description }

    public var recoverySuggestion: String? {
        switch self {
        case .nothingFound:
            return "Search again with the film's IMDb identifier, or rename the file to its "
                + "title and year — a release name the parser cannot read finds nothing."
        }
    }
}
#endif
