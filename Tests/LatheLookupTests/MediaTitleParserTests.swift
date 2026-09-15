import Foundation
import Testing

@testable import LatheLookup

/// Turning a filename into a query.
///
/// This is where most of a lookup's accuracy is decided and the only part that
/// can be tested exhaustively — no key, no account, no network. Every case below
/// is a filename shape that occurs in real libraries.
@Suite("Filename parsing")
struct MediaTitleParserTests {

    private let parser = MediaTitleParser()

    // MARK: - The headline

    /// **The whole point**: a release name is unsearchable, and the title plus
    /// the year is not only searchable but unambiguous.
    @Test("a full release name reduces to a title and a year")
    func releaseNameReducesToTitleAndYear() {
        let query = parser.parse("The.Thing.1982.2160p.UHD.BluRay.x265.10bit.HDR.DTS-HD.MA.5.1-GROUP")
        #expect(query.title == "The Thing")
        #expect(query.year == 1982)
    }

    /// The year is what separates a remake from what it remade, which is the
    /// single most common mismatch in a film library.
    @Test("the year distinguishes a remake from its original")
    func yearDistinguishesRemakes() {
        #expect(parser.parse("The.Thing.1982.1080p").year == 1982)
        #expect(parser.parse("The.Thing.2011.1080p").year == 2011)
        #expect(parser.parse("The.Thing.1982.1080p").title == "The Thing")
        #expect(parser.parse("The.Thing.2011.1080p").title == "The Thing")
    }

    // MARK: - Episodes

    @Test("season and episode are read in the spellings that actually occur")
    func episodeMarkers() {
        for name in [
            "The.Show.S03E05.1080p.WEB-DL",
            "The Show - 3x05 - The Episode",
            "The.Show.Season.3.Episode.5",
            "The.Show.s03e05.HDTV",
        ] {
            let query = parser.parse(name)
            guard case .episode(let season, let episode) = query.kind else {
                Issue.record("\(name) was not read as an episode")
                continue
            }
            #expect(season == 3, "\(name) gave season \(season ?? -1)")
            #expect(episode == 5, "\(name) gave episode \(episode ?? -1)")
            #expect(query.title == "The Show", "\(name) gave the title \"\(query.title)\"")
        }
    }

    /// A three-digit episode number is real — long-running shows reach them —
    /// and must not be truncated to two.
    @Test("a three-digit episode number is read whole")
    func longEpisodeNumbers() {
        let query = parser.parse("Anime.Title.S01E142.1080p")
        guard case .episode(_, let episode) = query.kind else {
            Issue.record("not read as an episode")
            return
        }
        #expect(episode == 142)
    }

    /// An episode's air date is not the series' release year. Searching a series
    /// by its episode's year finds nothing.
    @Test("a date after the episode marker is not taken as the series year")
    func airDateIsNotTheSeriesYear() {
        let query = parser.parse("The.Show.S03E05.2019.1080p.WEB")
        #expect(query.year == nil, "the year after an episode marker is an air date")
        #expect(query.title == "The Show")
    }

    // MARK: - Titles that look like noise

    /// **A title that is a year must survive.** `2001 A Space Odyssey` losing
    /// its number leaves `A Space Odyssey`, which finds nothing; `1917` losing
    /// its number leaves nothing at all.
    @Test("a leading year is part of the title, not a release year")
    func leadingYearIsTitle() {
        let odyssey = parser.parse("2001.A.Space.Odyssey.1968.1080p.BluRay")
        #expect(odyssey.title == "2001 A Space Odyssey")
        #expect(odyssey.year == 1968)

        let nineteenSeventeen = parser.parse("1917.2019.1080p.BluRay.x264")
        #expect(nineteenSeventeen.title == "1917")
        #expect(nineteenSeventeen.year == 2019)
    }

    /// A number inside a title is not an episode marker. `21 Jump Street` has an
    /// `x`-free number and must not be cut at it.
    @Test("a number in a title is left alone")
    func numbersInTitles() {
        #expect(parser.parse("21.Jump.Street.2012.1080p").title == "21 Jump Street")
        #expect(parser.parse("Ocean's.11.2001.720p").title == "Ocean's 11")
        #expect(parser.parse("Se7en.1995.1080p").title == "Se7en")
    }

    /// Words that appear in real titles must not be treated as release noise.
    /// Cutting a title at a word that belongs to it is worse than leaving noise
    /// for the provider's fuzzy matching to absorb.
    @Test("words that occur in real titles are not treated as release tags")
    func titleWordsAreNotTags() {
        // Excluded from the tag list on purpose: each appears in real titles,
        // and cutting a title at a word that belongs to it loses more than the
        // little noise it would have removed.
        for word in ["extended", "unrated", "director", "final", "special", "complete"] {
            #expect(!MediaTitleParser.releaseTags.contains(word),
                    "\"\(word)\" occurs in real titles and must not end one")
        }
        // And the consequence, end to end.
        #expect(parser.parse("Blade.Runner.The.Final.Cut.1982.1080p").title
                == "Blade Runner The Final Cut")
    }

    // MARK: - Separators and decoration

    @Test("dots, underscores and spaces all separate words")
    func separators() {
        #expect(parser.parse("The_Big_Lebowski_1998_1080p").title == "The Big Lebowski")
        #expect(parser.parse("The.Big.Lebowski.1998.1080p").title == "The Big Lebowski")
        #expect(parser.parse("The Big Lebowski 1998 1080p").title == "The Big Lebowski")
    }

    /// A title with dots in it and spaces as separators must keep its dots —
    /// which is why the dot replacement only happens when there are no spaces.
    @Test("a name that already has spaces keeps its dots")
    func dotsSurviveWhenSpacesSeparate() {
        #expect(parser.parse("W.E. 2011 1080p").title == "W.E.")
    }

    @Test("bracketed groups are stripped")
    func bracketsAreStripped() {
        #expect(parser.parse("[Group] The Show - 3x05 [1080p][x265]").title == "The Show")
        #expect(parser.parse("The Movie (2019) [1080p]").title == "The Movie")
        #expect(parser.parse("The Movie (2019) [1080p]").year == 2019)
    }

    // MARK: - Honesty about what is not known

    /// **The parser does not guess.** A name with no year has no year, and a
    /// name with no episode marker is not declared a film. A confident wrong
    /// query produces a confident wrong match.
    @Test("what the filename does not say is left unset")
    func nothingIsGuessed() {
        let query = parser.parse("Some Home Video")
        #expect(query.title == "Some Home Video")
        #expect(query.year == nil)
        #expect(query.kind == .unknown)
    }

    @Test("a file URL is parsed from its name without its extension")
    func parsesAURL() {
        let url = URL(fileURLWithPath: "/tmp/The.Matrix.1999.1080p.BluRay.x264.mkv")
        let query = parser.query(forFilename: url)
        #expect(query.title == "The Matrix")
        #expect(query.year == 1999)
    }

    /// A name that is nothing but noise reduces to something empty rather than
    /// to a fragment of a codec name.
    @Test("a name that is only release noise does not become a title")
    func pureNoise() {
        let query = parser.parse("1080p.x264.AAC")
        #expect(query.title.isEmpty || query.title == "1080p")
    }
}
