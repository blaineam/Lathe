import Foundation

/// A subtitle track's language, in both of the forms a file stores.
///
/// ## Two fields, because one is too old to say enough
///
/// An MP4 track header (`mdhd`) holds a **three-letter ISO 639-2/T code** and
/// nothing else, so it cannot tell Brazilian Portuguese from European, or
/// Simplified Chinese from Traditional. A second, newer box (`elng`) holds a
/// **BCP 47 tag** that can. AVFoundation prefers the tag when it is there — a
/// `fr-CA` track is offered as "French (Canada)" — and falls back to the code;
/// players that predate `elng` read only the code. So
/// both are written, and they have to agree — a track tagged `pt-BR` whose code
/// says `und` shows as Portuguese in one app and "Unknown" in the next.
///
/// `AVAssetWriterInput.languageCode` is documented as ISO 639-2/T, and handing
/// it `"en"` does not fail: it writes a file whose language nothing recognises.
/// That is the trap this type exists to close.
public struct SubtitleLanguage: Sendable, Equatable, Hashable {

    /// The ISO 639-2/T code for the track header — `"eng"`, `"por"`, or
    /// `"und"` when the language is unknown.
    public let iso639_2: String

    /// The BCP 47 tag — `"en"`, `"pt-BR"` — or `nil` when there is nothing
    /// more specific to say than ``iso639_2``.
    public let bcp47: String?

    /// Undetermined, which is a real ISO 639-2 code and what a file should say
    /// when it does not know.
    public static let undetermined = SubtitleLanguage(iso639_2: "und", bcp47: nil)

    private init(iso639_2: String, bcp47: String?) {
        self.iso639_2 = iso639_2
        self.bcp47 = bcp47
    }

    /// Accepts a BCP 47 tag (`"en"`, `"pt-BR"`, `"zh-Hant"`), an ISO 639-1 code,
    /// or an ISO 639-2 code (`"eng"`, `"fre"`, `"fra"`), with `_` tolerated for
    /// `-` as Apple locale identifiers write it.
    ///
    /// - Throws: ``SubtitleError/invalidLanguage(_:)`` for anything that is not
    ///   syntactically a language tag. A well-formed tag whose language this
    ///   system does not know is kept as the BCP 47 tag with an `und` code,
    ///   rather than refused: the tag is still the most accurate thing to write.
    public init(_ code: String) throws {
        let tag = code.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-")
        guard Self.isWellFormed(tag) else { throw SubtitleError.invalidLanguage(code) }

        var primary = String(tag.split(separator: "-")[0]).lowercased()
        primary = Self.bibliographicToTerminology[primary] ?? primary
        if primary == "und" || primary == "zxx" || primary == "mul" {
            self.init(iso639_2: primary, bcp47: nil)
            return
        }

        let language = Locale.LanguageCode(primary)
        // `.alpha3` is the terminology code (`fra`, `deu`), which is what the
        // MP4 header uses.
        let alpha3 = language.identifier(.alpha3)
        let alpha2 = language.identifier(.alpha2)

        let subtags = tag.split(separator: "-").dropFirst().map(String.init)
        let canonicalPrimary = alpha2 ?? primary
        let rebuilt = ([canonicalPrimary] + subtags.map(Self.canonicalCase)).joined(separator: "-")

        if let alpha3, alpha3.count == 3 {
            self.init(iso639_2: alpha3, bcp47: rebuilt)
        } else {
            self.init(iso639_2: "und", bcp47: rebuilt)
        }
    }

    /// ISO 639-2 has two codes for twenty languages, and `Locale` knows only
    /// the terminology one: it answers `nil` for `fre` and `ger`, which are
    /// exactly the codes older tools and subtitle sites write. The list is
    /// closed — the standard froze it — so it is spelled out.
    static let bibliographicToTerminology: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho",
        "cze": "ces", "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu",
        "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri", "may": "msa",
        "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym",
    ]

    /// BCP 47's shape: a 2–3 letter primary tag (or 4–8 for registered ones),
    /// then subtags of 1–8 letters or digits. Not a full validator, and not
    /// meant to be; it keeps punctuation, paths and empty strings out of a
    /// track header.
    static func isWellFormed(_ tag: String) -> Bool {
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first, (2...8).contains(first.count),
              first.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return false }
        return parts.dropFirst().allSatisfy { part in
            (1...8).contains(part.count) && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    /// `hant` → `Hant`, `br` → `BR`, following BCP 47's conventions: a
    /// four-letter subtag is a script, a two-letter one a region.
    private static func canonicalCase(_ subtag: String) -> String {
        switch subtag.count {
        case 2: subtag.uppercased()
        case 4 where subtag.allSatisfy(\.isLetter): subtag.prefix(1).uppercased() + subtag.dropFirst().lowercased()
        default: subtag.lowercased()
        }
    }
}
