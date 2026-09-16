import Foundation
import LatheMeta
import Testing

@testable import LatheLookup

/// A transport that answers from a script instead of from the network, so a
/// provider's request building, response decoding and error mapping can all be
/// exercised without a key or an account.
///
/// Those are the parts that break when an API changes, and the parts a live
/// test covers least reliably — a live test of the 429 path requires being rate
/// limited on purpose.
actor ScriptedTransport: HTTPTransport {
    struct Reply {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    init(json: String, status: Int = 200) {
        self.init([Reply(status: status, body: Data(json.utf8))])
    }

    /// Replies chosen by what the request asked for rather than by arrival
    /// order. An unknown-kind search issues its film and series requests
    /// concurrently, so an ordered script hands them out by whichever hits the
    /// actor first — which makes any test of that path a coin toss.
    private var byPath: [String: Reply] = [:]

    init(byPath: [String: Reply]) { self.replies = []; self.byPath = byPath }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        let reply: Reply
        if let matched = byPath.first(where: { path.hasSuffix($0.key) })?.value {
            reply = matched
        } else if replies.isEmpty {
            reply = Reply(status: 200, body: Data("{}".utf8))
        } else {
            reply = replies.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: reply.headers
        )!
        return (reply.body, response)
    }
}

@Suite("Metadata providers")
struct ProviderTests {

    // MARK: - No key is a normal state

    /// **A provider with no credentials is not broken.** It is the state of
    /// every fresh install, and the error has to say what to do rather than
    /// report a failure — manual editing is the feature, and lookup accelerates
    /// it.
    @Test("an unconfigured provider says what it needs, and never reaches the network")
    func unconfiguredProviderExplainsItself() async throws {
        let transport = ScriptedTransport([])
        let tmdb = TMDbProvider(credentials: ProviderCredentials(), transport: transport)

        #expect(!tmdb.isConfigured)
        #expect(tmdb.credentialRequirement.contains("themoviedb.org"))

        await #expect(throws: LookupError.self) {
            try await tmdb.search(LookupQuery(title: "The Matrix"))
        }
        #expect(await transport.requests.isEmpty, "an unconfigured provider must not make a request")
    }

    /// **OpenSubtitles needs two credentials, and the second is not the user's.**
    /// A registered per-application User-Agent is required alongside the key, so
    /// a correct key alone still fails — with a 403 that explains nothing unless
    /// this is checked first.
    @Test("OpenSubtitles is unconfigured with a key alone, because the agent is also required")
    func openSubtitlesNeedsAnAgentAsWellAsAKey() async throws {
        let transport = ScriptedTransport([])
        let keyOnly = OpenSubtitlesProvider(
            credentials: ProviderCredentials(apiKey: "k"), transport: transport
        )
        #expect(!keyOnly.isConfigured, "a key alone is not enough for OpenSubtitles")
        #expect(keyOnly.credentialRequirement.lowercased().contains("user-agent"))

        await #expect(throws: LookupError.self) {
            try await keyOnly.search(SubtitleQuery(title: "The Matrix"))
        }
        #expect(await transport.requests.isEmpty)

        let both = OpenSubtitlesProvider(
            credentials: ProviderCredentials(apiKey: "k", userAgent: "App v1.0"),
            transport: transport
        )
        #expect(both.isConfigured)
    }

    // MARK: - Requests

    /// **A bearer credential goes in a header, never in the query string.**
    /// URLs are logged by proxies, caches and crash reporters; a credential in
    /// one is a credential published.
    ///
    /// This holds for the read access token, which TMDb accepts as a bearer.
    /// It cannot hold for a v3 API key, which TMDb accepts *only* as a query
    /// item — see `apiKeyGoesInTheQuery`. This test used a key of neither
    /// shape and asserted the header for both, which is how sending every
    /// credential as a bearer survived: the one shape most people actually
    /// copy was never exercised.
    @Test("a bearer credential is sent as a header and never appears in the URL")
    func keyIsNotInTheURL() async throws {
        let transport = ScriptedTransport(json: #"{"results":[]}"#)
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2ln"
        let tmdb = TMDbProvider(
            credentials: ProviderCredentials(apiKey: token), transport: transport
        )
        _ = try await tmdb.search(LookupQuery(title: "Heat", kind: .movie))

        let request = try #require(await transport.requests.first)
        let url = try #require(request.url?.absoluteString)
        #expect(!url.contains(token), "the credential leaked into the URL: \(url)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(url.contains("/search/movie"))
        #expect(url.contains("query=Heat"))
    }

    @Test("a year is sent as a year, and an episode query goes to the series endpoint")
    func queriesReachTheRightEndpoints() async throws {
        let movies = ScriptedTransport(json: #"{"results":[]}"#)
        _ = try await TMDbProvider(
            credentials: ProviderCredentials(apiKey: "k"), transport: movies
        ).search(LookupQuery(title: "Heat", year: 1995, kind: .movie))
        #expect(try #require(await movies.requests.first?.url?.absoluteString).contains("year=1995"))

        let series = ScriptedTransport(json: #"{"results":[]}"#)
        _ = try await TMDbProvider(
            credentials: ProviderCredentials(apiKey: "k"), transport: series
        ).search(LookupQuery(title: "The Show", kind: .episode(season: 3, episode: 5)))
        #expect(try #require(await series.requests.first?.url?.absoluteString).contains("/search/tv"))
    }

    // MARK: - Decoding

    @Test("a movie search decodes into candidates")
    func decodesAMovieSearch() async throws {
        let json = """
        {"page":1,"results":[
          {"id":603,"title":"The Matrix","original_title":"The Matrix",
           "overview":"A computer hacker learns...","release_date":"1999-03-30",
           "poster_path":"/f89U3ADr1oiB1s.jpg","vote_average":8.2},
          {"id":604,"title":"The Matrix Reloaded","release_date":"2003-05-15",
           "poster_path":"/9TGHDvWrqPBzKhrpJ.jpg","vote_average":7.0}
        ],"total_results":2}
        """
        let provider = TMDbProvider(
            credentials: ProviderCredentials(apiKey: "k"),
            transport: ScriptedTransport(json: json)
        )
        let matches = try await provider.search(LookupQuery(title: "The Matrix", kind: .movie))

        #expect(matches.count == 2)
        let first = try #require(matches.first)
        #expect(first.title == "The Matrix")
        #expect(first.year == 1999)
        #expect(first.kind == .movie)
        #expect(first.providerID == "603")
        #expect(first.id == "TMDb:603", "identifiers are namespaced so two providers can coexist")
        #expect(first.artworkReference == "/f89U3ADr1oiB1s.jpg")
        // 8.2 out of 10, normalised.
        #expect(abs((first.confidence ?? 0) - 0.82) < 0.001)
    }

    /// An episode's details must keep the SERIES name, which the episode
    /// endpoint does not repeat. A file whose show name is missing files itself
    /// nowhere, however correct its episode title is.
    @Test("episode details keep the series name and set the TV kind")
    func episodeDetailsCarryTheSeriesName() async throws {
        let json = """
        {"id":62085,"name":"The One With The Test","overview":"They test things.",
         "air_date":"2019-04-14","season_number":3,"episode_number":5}
        """
        let provider = TMDbProvider(
            credentials: ProviderCredentials(apiKey: "k"),
            transport: ScriptedTransport(json: json)
        )
        let match = MetadataMatch(
            provider: "TMDb", providerID: "1399", title: "A Series",
            kind: .tvShow, season: 3, episode: 5
        )
        let meta = try await provider.details(for: match)

        #expect(meta.title == "The One With The Test")
        #expect(meta.kind == .tvShow, "stik is what files it under TV Shows")
        #expect(meta.show?.seriesName == "A Series")
        #expect(meta.show?.seasonNumber == 3)
        #expect(meta.show?.episodeNumber == 5)
        #expect(meta.identifiers["tmdb"] == "1399")
    }

    @Test("movie details carry both identifiers when the provider knows them")
    func movieDetailsCarryIdentifiers() async throws {
        let json = """
        {"id":603,"title":"The Matrix","overview":"A long synopsis.",
         "tagline":"Welcome to the Real World.","release_date":"1999-03-30",
         "genres":[{"id":28,"name":"Action"}],"imdb_id":"tt0133093"}
        """
        let provider = TMDbProvider(
            credentials: ProviderCredentials(apiKey: "k"),
            transport: ScriptedTransport(json: json)
        )
        let meta = try await provider.details(
            for: MetadataMatch(provider: "TMDb", providerID: "603", title: "The Matrix", kind: .movie)
        )

        #expect(meta.title == "The Matrix")
        #expect(meta.kind == .movie)
        #expect(meta.genre == "Action")
        #expect(meta.identifiers["tmdb"] == "603")
        #expect(meta.identifiers["imdb"] == "tt0133093",
                "the IMDb id is what makes a later subtitle search unambiguous")
        // desc and ldes are different atoms; the tagline is the short one.
        #expect(meta.summary == "Welcome to the Real World.")
        #expect(meta.longDescription == "A long synopsis.")
    }

    /// Every wire field is optional on purpose. A provider that stops sending
    /// one breaks every lookup at once if it was declared required — and the
    /// failure arrives as a decoding error about a field nobody was using.
    @Test("a response missing optional fields still decodes")
    func sparseResponsesDecode() async throws {
        let provider = TMDbProvider(
            credentials: ProviderCredentials(apiKey: "k"),
            transport: ScriptedTransport(json: #"{"results":[{"id":1}]}"#)
        )
        let matches = try await provider.search(LookupQuery(title: "x", kind: .movie))
        #expect(matches.count == 1)
        #expect(matches.first?.title == "")
        #expect(matches.first?.year == nil)
    }

    /// An ambiguous query must not silently become a film. Concatenating films
    /// above series would make every unlabelled name resolve to a film, which is
    /// a guess dressed as an ordering.
    @Test("an ambiguous query interleaves films and series rather than ranking one above the other")
    func ambiguousQueriesInterleave() {
        let films = (1...3).map {
            MetadataMatch(provider: "TMDb", providerID: "f\($0)", title: "F\($0)", kind: .movie)
        }
        let series = (1...2).map {
            MetadataMatch(provider: "TMDb", providerID: "s\($0)", title: "S\($0)", kind: .tvShow)
        }
        let merged = TMDbProvider.interleave(films, series)
        #expect(merged.map(\.providerID) == ["f1", "s1", "f2", "s2", "f3"])
        #expect(merged.count == films.count + series.count, "nothing is dropped")
    }

    // MARK: - Errors that tell the user what to do

    /// A bad key, an exhausted quota and an unreachable server need three
    /// different responses from the user, and the status code already
    /// distinguishes them — collapsing them into "request failed" is what
    /// produces support questions.
    @Test("each failure maps to the error that says what to do about it")
    func statusCodesMapToDistinctErrors() async throws {
        func search(status: Int, headers: [String: String] = [:], body: String = "{}") async -> Error? {
            let transport = ScriptedTransport([
                .init(status: status, body: Data(body.utf8), headers: headers)
            ])
            let provider = TMDbProvider(
                credentials: ProviderCredentials(apiKey: "k"), transport: transport
            )
            do {
                _ = try await provider.search(LookupQuery(title: "x", kind: .movie))
                return nil
            } catch {
                return error
            }
        }

        let unauthorised = await search(
            status: 401, body: #"{"status_message":"Invalid API key."}"#
        )
        guard case .unauthorised(_, let detail)? = unauthorised as? LookupError else {
            Issue.record("401 gave \(String(describing: unauthorised))")
            return
        }
        #expect(detail.contains("Invalid API key"), "the provider's own message is more use than the status")

        let limited = await search(status: 429, headers: ["Retry-After": "30"])
        guard case .rateLimited(_, let retryAfter)? = limited as? LookupError else {
            Issue.record("429 gave \(String(describing: limited))")
            return
        }
        #expect(retryAfter == 30)

        let broken = await search(status: 500)
        guard case .transport? = broken as? LookupError else {
            Issue.record("500 gave \(String(describing: broken))")
            return
        }
    }

    /// An API that changed shape is a specific, nameable failure rather than a
    /// crash or an empty result that looks like "no matches".
    @Test("an unexpected payload is reported as a malformed response, not as no results")
    func malformedPayloadIsNamed() async throws {
        let provider = TMDbProvider(
            credentials: ProviderCredentials(apiKey: "k"),
            transport: ScriptedTransport(json: #"{"unexpected":true}"#)
        )
        do {
            _ = try await provider.search(LookupQuery(title: "x", kind: .movie))
            Issue.record("a payload with no results decoded successfully")
        } catch let error as LookupError {
            guard case .malformedResponse = error else {
                Issue.record("got \(error)")
                return
            }
        }
    }

    @Test("an empty query is refused before a request is made")
    func emptyQueryIsRefused() async throws {
        let transport = ScriptedTransport([])
        let provider = TMDbProvider(
            credentials: ProviderCredentials(apiKey: "k"), transport: transport
        )
        await #expect(throws: LookupError.self) {
            try await provider.search(LookupQuery(title: "   ", kind: .movie))
        }
        #expect(await transport.requests.isEmpty)
    }

    // MARK: - Subtitles

    @Test("a subtitle search decodes, and marks what a user needs to judge by")
    func decodesASubtitleSearch() async throws {
        let json = """
        {"data":[
          {"id":"7061050","attributes":{"language":"en","download_count":12045,
           "ratings":8.5,"hearing_impaired":false,"machine_translated":false,
           "release":"The.Matrix.1999.1080p.BluRay.x264",
           "files":[{"file_id":7061050,"file_name":"The.Matrix.1999.srt"}]}},
          {"id":"7061051","attributes":{"language":"fr","download_count":3,
           "hearing_impaired":true,"machine_translated":true,
           "files":[{"file_id":7061051,"file_name":"matrix.fr.srt"}]}}
        ]}
        """
        let provider = OpenSubtitlesProvider(
            credentials: ProviderCredentials(apiKey: "k", userAgent: "App v1"),
            transport: ScriptedTransport(json: json)
        )
        let results = try await provider.search(SubtitleQuery(title: "The Matrix"))

        #expect(results.count == 2)
        let first = try #require(results.first)
        #expect(first.fileID == 7_061_050)
        #expect(first.language == "en")
        #expect(first.downloadCount == 12_045)
        #expect(first.releaseName == "The.Matrix.1999.1080p.BluRay.x264",
                "the release a subtitle was timed against predicts whether it will be in sync")
        #expect(first.isMachineTranslated == false)
        // Machine translation is frequently unusable and the API says so, which
        // is worth knowing BEFORE spending a metered download on it.
        #expect(results.last?.isMachineTranslated == true)
        #expect(results.last?.isHearingImpaired == true)
    }

    /// An entry with no downloadable file is not a candidate. Returning one
    /// produces a row the user can select and cannot download.
    @Test("an entry with no file is dropped rather than offered")
    func entriesWithoutFilesAreDropped() async throws {
        let json = #"{"data":[{"id":"1","attributes":{"language":"en","files":[]}}]}"#
        let provider = OpenSubtitlesProvider(
            credentials: ProviderCredentials(apiKey: "k", userAgent: "App v1"),
            transport: ScriptedTransport(json: json)
        )
        #expect(try await provider.search(SubtitleQuery(title: "x")).isEmpty)
    }

    /// An identifier beats a title: it removes the remake problem outright
    /// rather than ranking around it.
    @Test("an IMDb id is used instead of the title when one is known")
    func imdbIdentifierIsPreferred() async throws {
        let transport = ScriptedTransport(json: #"{"data":[]}"#)
        let provider = OpenSubtitlesProvider(
            credentials: ProviderCredentials(apiKey: "k", userAgent: "App v1"),
            transport: transport
        )
        _ = try await provider.search(
            SubtitleQuery(title: "The Thing", imdbID: "tt0084787", season: nil, episode: nil)
        )
        let url = try #require(await transport.requests.first?.url?.absoluteString)
        #expect(url.contains("imdb_id=0084787"))
        #expect(!url.contains("query="), "a title search is redundant once the id is known")
    }

    /// The download is two requests, and the second must not carry credentials:
    /// the link is pre-signed and sending a key to it would hand it to a host
    /// that never needed one.
    @Test("downloading fetches the ticket then the file, without sending the key to the file host")
    func downloadDoesNotLeakTheKeyToTheFileHost() async throws {
        let ticket = #"{"link":"https://files.example.com/x.srt","file_name":"x.srt","remaining":19}"#
        let subtitle = "1\n00:00:01,000 --> 00:00:02,000\nHello\n"
        let transport = ScriptedTransport([
            .init(status: 200, body: Data(ticket.utf8)),
            .init(status: 200, body: Data(subtitle.utf8)),
        ])
        let provider = OpenSubtitlesProvider(
            credentials: ProviderCredentials(apiKey: "SECRET", userAgent: "App v1"),
            transport: transport
        )

        let document = try await provider.download(
            SubtitleCandidate(fileID: 1, fileName: "x.srt", language: "en")
        )
        #expect(document.text == subtitle)
        #expect(document.format == .subRip)
        #expect(document.remainingDownloads == 19, "the quota is low enough that a user can hit it")

        #expect(await transport.requests.count == 2)
        let fileRequest = try #require(await transport.requests.last)
        #expect(fileRequest.url?.host == "files.example.com")
        #expect(fileRequest.value(forHTTPHeaderField: "Api-Key") == nil,
                "the key was sent to the file host")
    }

    @Test("the subtitle format is read from the contents when the name does not say")
    func subtitleFormatIsSniffed() {
        #expect(SubtitleFormat(filename: "a.srt", contents: Data()) == .subRip)
        #expect(SubtitleFormat(filename: "a.vtt", contents: Data()) == .webVTT)
        #expect(SubtitleFormat(filename: "a.ass", contents: Data()) == .substationAlpha)
        // A .txt holding SubRip is common, and the cue arrow is unmistakable.
        #expect(SubtitleFormat(
            filename: "a.txt",
            contents: Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8)
        ) == .subRip)
        #expect(SubtitleFormat(filename: "a.txt", contents: Data("WEBVTT\n\n".utf8)) == .webVTT)
        #expect(SubtitleFormat(filename: "a.bin", contents: Data([0, 1, 2])) == .unknown)
    }

    /// Subtitles in the wild are frequently Latin-1 rather than UTF-8 — a file
    /// that is mostly ASCII decodes as UTF-8 right up until an accent.
    @Test("a subtitle that is not UTF-8 still decodes")
    func nonUTF8SubtitlesDecode() {
        // 0xE9 is "é" in Latin-1 and invalid on its own in UTF-8.
        let latin1 = Data([0x43, 0x61, 0x66, 0xE9])   // "Café"
        let document = SubtitleDocument(data: latin1, format: .subRip, language: "fr")
        #expect(document.text?.contains("Caf") == true)
        #expect(document.text != nil, "a Latin-1 subtitle came back as nothing")
    }

    // MARK: - The query bridge

    /// A caller should not describe the same episode twice.
    @Test("a subtitle query can be built from a media query")
    func subtitleQueryFromLookupQuery() {
        let media = LookupQuery(title: "The Show", year: 2019, kind: .episode(season: 3, episode: 5))
        let subtitles = SubtitleQuery(media, imdbID: "tt1234567", languages: ["en", "fr"])

        #expect(subtitles.title == "The Show")
        #expect(subtitles.season == 3)
        #expect(subtitles.episode == 5)
        #expect(subtitles.imdbID == "tt1234567")
        #expect(subtitles.languages == ["en", "fr"])
    }

    // MARK: - The two TMDb credentials

    /// **TMDb issues two credentials and they are not interchangeable.**
    ///
    /// Settings → API shows an API Key and an API Read Access Token on the same
    /// page. Only the token is a bearer credential; the key is accepted solely
    /// as a query item. Sending everything as a bearer token made the more
    /// commonly copied of the two fail every request.
    @Test("a v3 API key is sent as a query item, not as a bearer token")
    func apiKeyGoesInTheQuery() async throws {
        let transport = ScriptedTransport(json: #"{"results":[]}"#)
        let key = "0123456789abcdef0123456789abcdef"
        let tmdb = TMDbProvider(
            credentials: ProviderCredentials(apiKey: key), transport: transport)

        _ = try await tmdb.search(LookupQuery(title: "A Silent Voice", kind: .movie))

        let request = try #require(await transport.requests.first)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.contains { $0.name == "api_key" && $0.value == key } == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("a v4 read access token is sent as a bearer header, and never in the URL")
    func readAccessTokenGoesInTheHeader() async throws {
        let transport = ScriptedTransport(json: #"{"results":[]}"#)
        // A JWT's shape: three non-empty dot-separated segments.
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2lnbmF0dXJl"
        let tmdb = TMDbProvider(
            credentials: ProviderCredentials(apiKey: token), transport: transport)

        _ = try await tmdb.search(LookupQuery(title: "A Silent Voice", kind: .movie))

        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        // A URL is logged by proxies, caches and crash reporters. Where there
        // is a choice, the credential does not go in one.
        #expect(request.url?.absoluteString.contains(token) == false)
    }

    @Test("the two credential shapes are told apart by shape, not by length")
    func credentialShapeDetection() {
        #expect(TMDbProvider.isReadAccessToken("a.b.c"))
        #expect(!TMDbProvider.isReadAccessToken("0123456789abcdef0123456789abcdef"))
        #expect(!TMDbProvider.isReadAccessToken("a..c"), "an empty segment is not a JWT")
        #expect(!TMDbProvider.isReadAccessToken("a.b"))
        #expect(!TMDbProvider.isReadAccessToken(""))
    }

    // MARK: - A rejected key is not an empty result

    /// **The failure mode this replaces was the expensive one.** An unknown-kind
    /// search runs a film search and a series search together. Both were
    /// wrapped in `try?`, so a 401 became two empty arrays and the caller
    /// reported "nothing matched" — which sends someone to edit their search
    /// text when the actual problem is their credentials.
    @Test("a rejected key surfaces as unauthorised, not as an empty result")
    func rejectedKeyIsNotSilent() async throws {
        let transport = ScriptedTransport(byPath: [
            "/search/movie": .init(
                status: 401, body: Data(#"{"status_message":"Invalid API key"}"#.utf8)),
            "/search/tv": .init(
                status: 401, body: Data(#"{"status_message":"Invalid API key"}"#.utf8)),
        ])
        let tmdb = TMDbProvider(
            credentials: ProviderCredentials(apiKey: "wrong"), transport: transport)

        await #expect(throws: LookupError.self) {
            try await tmdb.search(LookupQuery(title: "A Silent Voice", kind: .unknown))
        }
    }

    /// One side failing is survivable, and must stay so: a film search can fail
    /// while the series search answers perfectly well.
    @Test("one side failing still returns the other side's results")
    func oneSideFailingIsSurvivable() async throws {
        let transport = ScriptedTransport(byPath: [
            "/search/movie": .init(status: 500, body: Data("{}".utf8)),
            "/search/tv": .init(status: 200, body: Data(#"""
            {"results":[{"id":7,"name":"A Show","first_air_date":"2011-04-17"}]}
            """#.utf8)),
        ])
        let tmdb = TMDbProvider(
            credentials: ProviderCredentials(apiKey: "0123456789abcdef0123456789abcdef"),
            transport: transport)

        let matches = try await tmdb.search(LookupQuery(title: "A Show", kind: .unknown))
        #expect(matches.count == 1)
        #expect(matches.first?.title == "A Show")
    }


    // MARK: - The message a person actually sees

    /// **An `Error` without `LocalizedError` reports as a case index.** This
    /// shipped: a sandboxed app with no outgoing-connections entitlement put
    /// "LatheLookup.LookupError error 4." in front of a user, which tells them
    /// to go and count enum cases.
    @Test("every failure explains itself in words")
    func errorsAreReadable() {
        let cases: [LookupError] = [
            .notConfigured(provider: "TMDb", requirement: "a key"),
            .unauthorised(provider: "TMDb", detail: "401"),
            .rateLimited(provider: "TMDb", retryAfter: 30),
            .malformedResponse(provider: "TMDb", detail: "no results field"),
            .transport(provider: "TMDb", detail: "offline"),
            .emptyQuery,
        ]
        for failure in cases {
            let message = (failure as any Error).localizedDescription
            #expect(message == failure.description)
            // The generic NSError text this replaces looks like
            // "... (LatheLookup.LookupError error 4.)".
            #expect(!message.contains("LookupError error"))
            #expect(!message.isEmpty)
            #expect(failure.recoverySuggestion?.isEmpty == false)
        }
    }

    /// The transport case is the one that was misread as a credential problem,
    /// so its advice names the cause that is easy to miss.
    @Test("an unreachable provider mentions the sandbox entitlement")
    func transportMentionsTheEntitlement() {
        let failure = LookupError.transport(provider: "TMDb", detail: "offline")
        #expect(failure.recoverySuggestion?.contains("entitlement") == true)
    }

}
