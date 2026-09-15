import Foundation
import LatheMeta

/// Turns a filename into something worth searching for.
///
/// ## Why this is the important part
///
/// A lookup is only as good as its query, and what the user has is a file
/// called `The.Thing.1982.2160p.UHD.BluRay.x265.10bit.HDR.DTS-HD.MA.5.1-GROUP.mkv`.
/// Searching for that returns nothing. Searching for `The Thing` with the year
/// `1982` returns the right film first — and distinguishes it from the 2011
/// prequel of the same name, which is exactly the mismatch a user would
/// otherwise have to correct by hand.
///
/// So most of the value of an online lookup is in this type, and this type needs
/// no network, no API key and no account. It is also the only part that can be
/// tested exhaustively, which is why it is separated from the providers rather
/// than living inside them.
///
/// ## What it does not try to do
///
/// It does not guess. Where a filename gives up no year, the year is `nil`
/// rather than a plausible one; where it gives up no season or episode, the kind
/// is ``LookupQuery/Kind/unknown`` rather than `.movie`. A confident wrong query
/// produces a confident wrong match, and a confident wrong match applied to a
/// library is the failure this whole feature has to avoid.
public struct MediaTitleParser: Sendable {

    public init() {}

    /// A query for the file at `url`, from its name alone.
    public func query(forFilename url: URL) -> LookupQuery {
        parse(url.deletingPathExtension().lastPathComponent)
    }

    /// A query from a bare name, extension already removed.
    public func parse(_ rawName: String) -> LookupQuery {
        // Separators first: release names use dots or underscores where a title
        // has spaces, and every later pattern is written in terms of spaces.
        var name = rawName
            .replacingOccurrences(of: "_", with: " ")
        let dotsAreSeparators = !name.contains(" ")
        if dotsAreSeparators {
            name = name.replacingOccurrences(of: ".", with: " ")
        }
        name = name.replacingOccurrences(of: "  ", with: " ")

        let episode = Self.episodeMarker(in: name)
        let year = Self.year(in: name, before: episode?.range.lowerBound)

        // The title is whatever comes before the first thing that is definitely
        // not part of it — the episode marker, the year, or the first release
        // tag. Taking the earliest of those is what keeps a title containing a
        // number ("2001 A Space Odyssey") from being cut at the number, because
        // a leading year is not treated as a year at all.
        var cut = name.endIndex
        if let episode { cut = min(cut, episode.range.lowerBound) }
        if let yearRange = year?.range { cut = min(cut, yearRange.lowerBound) }
        if let tag = Self.firstReleaseTag(in: name) { cut = min(cut, tag) }

        var title = String(name[name.startIndex..<cut])
        title = Self.tidy(title, dotsAreSeparators: dotsAreSeparators)

        let kind: LookupQuery.Kind
        if let episode {
            kind = .episode(season: episode.season, episode: episode.episode)
        } else if year != nil {
            // A year and no episode marker is a film far more often than not,
            // but "far more often than not" is a ranking hint, not a fact — so
            // the kind stays unknown and the year does the disambiguating.
            kind = .unknown
        } else {
            kind = .unknown
        }

        return LookupQuery(title: title, year: year?.value, kind: kind)
    }

    // MARK: - Episode markers

    struct EpisodeMarker {
        var season: Int?
        var episode: Int?
        var range: Range<String.Index>
    }

    /// The season and episode numbers, in the spellings that actually turn up.
    ///
    /// `S03E05` is the common one. `3x05` is the older convention and still
    /// widespread. `Season 3 Episode 5` appears in files named by people rather
    /// than by tools. Anything else is left alone rather than guessed at: a bare
    /// `305` is as likely to be part of a title as an episode number.
    static func episodeMarker(in name: String) -> EpisodeMarker? {
        let patterns: [(String, isVerbose: Bool)] = [
            ("[Ss]([0-9]{1,2})[ ._-]?[Ee]([0-9]{1,3})", false),
            ("(?<![0-9])([0-9]{1,2})[xX]([0-9]{1,3})(?![0-9])", false),
            ("[Ss]eason[ ._-]?([0-9]{1,2})[ ._-]+[Ee]pisode[ ._-]?([0-9]{1,3})", true),
        ]
        for (pattern, _) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let full = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = regex.firstMatch(in: name, range: full),
                  let range = Range(match.range, in: name),
                  let seasonRange = Range(match.range(at: 1), in: name),
                  let episodeRange = Range(match.range(at: 2), in: name)
            else { continue }
            return EpisodeMarker(
                season: Int(name[seasonRange]),
                episode: Int(name[episodeRange]),
                range: range
            )
        }
        return nil
    }

    // MARK: - Years

    struct YearMatch {
        var value: Int
        var range: Range<String.Index>
    }

    /// A release year: four digits in a plausible range, not at the very start.
    ///
    /// The leading-position exclusion is what keeps `2001 A Space Odyssey` from
    /// losing its title, and `1917` from becoming a film with no name. A year
    /// that IS the title is at the front; a year that qualifies the title is
    /// after it.
    ///
    /// The **last** plausible year wins when there are several, because release
    /// names put the encode year after the film's: `Blade.Runner.1982.2007.
    /// Final.Cut` is a 1982 film, and taking the first match is right, but
    /// `The.Matrix.1999.1080p` has a resolution that is not a year and must not
    /// be read as one — hence the upper bound.
    static func year(in name: String, before limit: String.Index?) -> YearMatch? {
        guard let regex = try? NSRegularExpression(pattern: "(?<![0-9])(19[0-9]{2}|20[0-9]{2})(?![0-9])")
        else { return nil }
        let full = NSRange(name.startIndex..<name.endIndex, in: name)

        var best: YearMatch?
        regex.enumerateMatches(in: name, range: full) { match, _, _ in
            guard let match, let range = Range(match.range, in: name),
                  let value = Int(name[range])
            else { return }
            // A year at the very start is the title.
            guard range.lowerBound != name.startIndex else { return }
            // Past an episode marker it is an air date, not a release year, and
            // searching a series by its episode's year finds nothing.
            if let limit, range.lowerBound >= limit { return }
            if best == nil { best = YearMatch(value: value, range: range) }
        }
        return best
    }

    // MARK: - Release noise

    /// Words that are never part of a title, so the first one marks where the
    /// title ended.
    ///
    /// An allowlist of noise rather than a denylist of titles, and kept to terms
    /// that are unambiguous: `Extended` and `Unrated` are deliberately absent
    /// because they appear in real titles, and cutting a title at a word that
    /// belongs to it is worse than leaving a little noise for the provider's own
    /// fuzzy matching to absorb.
    static let releaseTags: Set<String> = [
        "1080p", "1080i", "720p", "480p", "2160p", "4k", "uhd", "hd", "sd",
        "bluray", "blu-ray", "brrip", "bdrip", "dvdrip", "dvdscr", "webrip",
        "web-dl", "webdl", "hdtv", "hdrip", "camrip", "cam", "ts", "tc", "r5",
        "x264", "x265", "h264", "h265", "hevc", "avc", "xvid", "divx", "av1",
        "aac", "ac3", "dts", "dd5", "ddp5", "truehd", "atmos", "flac", "mp3",
        "hdr", "hdr10", "dolby", "dv", "sdr", "10bit", "8bit", "remux", "proper",
        "repack", "internal", "limited", "multi", "dual", "subbed", "dubbed",
    ]

    /// Where the release noise starts, if it does.
    static func firstReleaseTag(in name: String) -> String.Index? {
        var index = name.startIndex
        var earliest: String.Index?
        for token in name.split(separator: " ", omittingEmptySubsequences: false) {
            let cleaned = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[](){}-"))
            if releaseTags.contains(cleaned) {
                earliest = index
                break
            }
            index = name.index(index, offsetBy: token.count + 1, limitedBy: name.endIndex) ?? name.endIndex
            if index >= name.endIndex { break }
        }
        return earliest
    }

    /// Trims the punctuation a cut leaves behind, and the bracketed groups that
    /// wrap a whole name.
    ///
    /// - Parameter dotsAreSeparators: whether dots in this name stood in for
    ///   spaces. It decides whether a trailing dot is noise or part of the
    ///   title: `The.Movie.2019` leaves one behind and `W.E. 2011` does not —
    ///   trimming it there turns a real film into `W.E`, which finds nothing.
    static func tidy(_ text: String, dotsAreSeparators: Bool = true) -> String {
        var out = text
        // A name wrapped entirely in brackets keeps its contents.
        while out.hasPrefix("["), out.hasSuffix("]"), out.count > 2 {
            out = String(out.dropFirst().dropLast())
        }
        // Drop bracketed groups anywhere — release tags, scene names, hashes.
        if let regex = try? NSRegularExpression(pattern: "[\\[{(][^\\]})]*[\\]})]") {
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..<out.endIndex, in: out), withTemplate: " "
            )
        }
        out = out.replacingOccurrences(of: "-", with: " ")
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }

        // Bracket characters are trimmed as well as whole bracketed groups,
        // because a cut inside a group leaves an unmatched one behind: a year
        // written as `(2019)` puts the cut after the opening parenthesis, and
        // `The Movie (` is what the provider would then be asked about.
        let trimmed = dotsAreSeparators ? " .-_:([{)]}" : " -_:([{)]}"
        return out.trimmingCharacters(in: CharacterSet(charactersIn: trimmed))
    }
}
