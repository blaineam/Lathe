import Foundation
import LatheCore
import LatheMeta

/// Film and television metadata from TMDb, using the user's own API key.
///
/// ## Attribution
///
/// TMDb's terms require an application using their API to say so and to show
/// their logo. That is a user-interface obligation this module cannot discharge
/// on its own — see ``TMDbProvider/attribution``, which exists so the string is
/// in the library rather than remembered by each integrator.
///
/// ## What is verified and what is not
///
/// The request construction, the response decoding and the error mapping are
/// covered by tests against recorded payloads. What is **not** verified here is
/// that those payloads still match what the API sends: that needs a key, and
/// there is none in this repository by design. The live tests are opt-in behind
/// `LATHE_LOOKUP_NETWORK_TESTS`, and an API change shows up as a
/// ``LookupError/malformedResponse(provider:detail:)`` naming the field rather
/// than as a crash.
public struct TMDbProvider: MetadataProvider {

    public let name = "TMDb"

    /// The notice an application using this provider is obliged to show.
    public static let attribution =
        "This product uses the TMDB API but is not endorsed or certified by TMDB."

    public var credentialRequirement: String {
        "a TMDb API key, created for free at themoviedb.org under Settings → API"
    }

    private let credentials: ProviderCredentials
    private let transport: any HTTPTransport
    private let baseURL: URL
    private let imageBaseURL: URL

    public init(
        credentials: ProviderCredentials,
        transport: any HTTPTransport = URLSessionTransport(),
        baseURL: URL = URL(string: "https://api.themoviedb.org/3")!,
        imageBaseURL: URL = URL(string: "https://image.tmdb.org/t/p")!
    ) {
        self.credentials = credentials
        self.transport = transport
        self.baseURL = baseURL
        self.imageBaseURL = imageBaseURL
    }

    public var isConfigured: Bool { credentials.hasKey }

    // MARK: - Searching

    public func search(_ query: LookupQuery) async throws -> [MetadataMatch] {
        try requireConfigured()
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LookupError.emptyQuery }

        switch query.kind {
        case .movie:
            return try await searchMovies(query)
        case .episode:
            return try await searchSeries(query)
        case .unknown:
            // Both, ordered by the provider's own popularity within each kind.
            // Interleaved rather than concatenated: putting every film above
            // every series would make an ambiguous name always resolve to a
            // film, which is a guess dressed as an ordering.
            async let movies = try? searchMovies(query)
            async let series = try? searchSeries(query)
            return Self.interleave(await movies ?? [], await series ?? [])
        }
    }

    private func searchMovies(_ query: LookupQuery) async throws -> [MetadataMatch] {
        var items = [URLQueryItem(name: "query", value: query.title)]
        if let year = query.year { items.append(URLQueryItem(name: "year", value: String(year))) }
        items.append(URLQueryItem(name: "language", value: query.language))

        let payload: TMDbSearchResponse<TMDbMovie> = try await get("/search/movie", items)
        return payload.results.map { movie in
            MetadataMatch(
                provider: name,
                providerID: String(movie.id),
                title: movie.title ?? movie.originalTitle ?? "",
                year: Self.year(from: movie.releaseDate),
                overview: movie.overview,
                kind: .movie,
                artworkReference: movie.posterPath,
                confidence: movie.voteAverage.map { min(1, $0 / 10) }
            )
        }
    }

    private func searchSeries(_ query: LookupQuery) async throws -> [MetadataMatch] {
        var items = [URLQueryItem(name: "query", value: query.title)]
        if let year = query.year {
            items.append(URLQueryItem(name: "first_air_date_year", value: String(year)))
        }
        items.append(URLQueryItem(name: "language", value: query.language))

        let payload: TMDbSearchResponse<TMDbSeries> = try await get("/search/tv", items)
        var season: Int?
        var episode: Int?
        if case .episode(let s, let e) = query.kind { season = s; episode = e }

        return payload.results.map { series in
            MetadataMatch(
                provider: name,
                providerID: String(series.id),
                title: series.name ?? series.originalName ?? "",
                year: Self.year(from: series.firstAirDate),
                overview: series.overview,
                kind: .tvShow,
                season: season,
                episode: episode,
                artworkReference: series.posterPath,
                confidence: series.voteAverage.map { min(1, $0 / 10) }
            )
        }
    }

    /// One from each list in turn, so an ambiguous query does not silently
    /// become a film.
    static func interleave(_ a: [MetadataMatch], _ b: [MetadataMatch]) -> [MetadataMatch] {
        var out: [MetadataMatch] = []
        var indexA = a.startIndex
        var indexB = b.startIndex
        while indexA < a.endIndex || indexB < b.endIndex {
            if indexA < a.endIndex { out.append(a[indexA]); indexA += 1 }
            if indexB < b.endIndex { out.append(b[indexB]); indexB += 1 }
        }
        return out
    }

    // MARK: - Details

    public func details(for match: MetadataMatch) async throws -> MediaMetadata {
        try requireConfigured()
        let language = [URLQueryItem(name: "language", value: "en-US")]

        if match.kind == .tvShow, let season = match.season, let episode = match.episode {
            // An episode's own title and synopsis, with the series name kept
            // from the match — the episode endpoint does not repeat it, and a
            // file whose show name is missing files itself nowhere.
            let detail: TMDbEpisode = try await get(
                "/tv/\(match.providerID)/season/\(season)/episode/\(episode)", language
            )
            var meta = MediaMetadata()
            meta.title = detail.name
            meta.summary = detail.overview
            meta.longDescription = detail.overview
            meta.date = Self.date(from: detail.airDate)
            meta.kind = .tvShow
            meta.show = ShowInfo(
                seriesName: match.title,
                seasonNumber: detail.seasonNumber ?? season,
                episodeNumber: detail.episodeNumber ?? episode,
                episodeID: (detail.episodeNumber ?? episode).description
            )
            meta.identifiers["tmdb"] = match.providerID
            return meta
        }

        if match.kind == .tvShow {
            let detail: TMDbSeries = try await get("/tv/\(match.providerID)", language)
            var meta = MediaMetadata()
            meta.title = detail.name
            meta.summary = detail.overview
            meta.longDescription = detail.overview
            meta.date = Self.date(from: detail.firstAirDate)
            meta.kind = .tvShow
            meta.genre = detail.genres?.first?.name
            meta.show = ShowInfo(seriesName: detail.name, network: detail.networks?.first?.name)
            meta.identifiers["tmdb"] = match.providerID
            return meta
        }

        let detail: TMDbMovie = try await get("/movie/\(match.providerID)", language)
        var meta = MediaMetadata()
        meta.title = detail.title ?? detail.originalTitle
        meta.summary = detail.tagline
        meta.longDescription = detail.overview
        meta.date = Self.date(from: detail.releaseDate)
        meta.kind = .movie
        meta.genre = detail.genres?.first?.name
        meta.identifiers["tmdb"] = match.providerID
        if let imdb = detail.imdbID, !imdb.isEmpty { meta.identifiers["imdb"] = imdb }
        return meta
    }

    // MARK: - Artwork

    public func artwork(for match: MetadataMatch, size: ArtworkSize) async throws -> Artwork? {
        guard let path = match.artworkReference, !path.isEmpty else { return nil }
        let component = switch size {
        case .thumbnail: "w185"
        case .embedded: "w500"
        case .original: "original"
        }
        let url = imageBaseURL.appendingPathComponent(component)
            .appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)

        let (data, response) = try await sendChecked(URLRequest(url: url))
        _ = response
        // Sniffed rather than taken from the Content-Type: the model records
        // what the bytes are, because that is what a player will go by.
        return Artwork(sniffing: data, role: .cover)
    }

    // MARK: - Plumbing

    private func requireConfigured() throws {
        guard isConfigured else {
            throw LookupError.notConfigured(provider: name, requirement: credentialRequirement)
        }
    }

    private func get<T: Decodable>(_ path: String, _ items: [URLQueryItem]) async throws -> T {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false
        ) else {
            throw LookupError.transport(provider: name, detail: "could not build a URL for \(path)")
        }
        components.queryItems = items
        guard let url = components.url else {
            throw LookupError.transport(provider: name, detail: "could not build a URL for \(path)")
        }

        var request = URLRequest(url: url)
        // The key goes in a header, never in the query string: a URL is logged
        // by proxies, caches and crash reporters, and a key in one is a key
        // published. TMDb accepts both; only one of them is safe.
        request.setValue("Bearer \(credentials.apiKey ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, _) = try await sendChecked(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LookupError.malformedResponse(provider: name, detail: String(describing: error))
        }
    }

    private func sendChecked(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as LookupError {
            throw error
        } catch {
            throw LookupError.transport(provider: name, detail: (error as NSError).localizedDescription)
        }
        try HTTPStatus.check(response, provider: name, body: data)
        return (data, response)
    }

    static func year(from text: String?) -> Int? {
        guard let text, text.count >= 4 else { return nil }
        return Int(text.prefix(4))
    }

    static func date(from text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        return MetadataDates.parse(text)
    }
}

// MARK: - Wire types

/// The subset of TMDb's payloads this module reads.
///
/// Every field optional, deliberately. A provider that adds a field breaks
/// nothing; a provider that stops sending one that was declared non-optional
/// breaks every lookup at once, and the failure arrives as a decoding error
/// about a field nobody was using.
struct TMDbSearchResponse<T: Decodable>: Decodable {
    var page: Int?
    var results: [T]
    var totalResults: Int?

    enum CodingKeys: String, CodingKey {
        case page, results
        case totalResults = "total_results"
    }
}

struct TMDbGenre: Decodable {
    var id: Int?
    var name: String?
}

struct TMDbNetwork: Decodable {
    var id: Int?
    var name: String?
}

struct TMDbMovie: Decodable {
    var id: Int
    var title: String?
    var originalTitle: String?
    var overview: String?
    var tagline: String?
    var releaseDate: String?
    var posterPath: String?
    var voteAverage: Double?
    var genres: [TMDbGenre]?
    var imdbID: String?

    enum CodingKeys: String, CodingKey {
        case id, title, overview, tagline, genres
        case originalTitle = "original_title"
        case releaseDate = "release_date"
        case posterPath = "poster_path"
        case voteAverage = "vote_average"
        case imdbID = "imdb_id"
    }
}

struct TMDbSeries: Decodable {
    var id: Int
    var name: String?
    var originalName: String?
    var overview: String?
    var firstAirDate: String?
    var posterPath: String?
    var voteAverage: Double?
    var genres: [TMDbGenre]?
    var networks: [TMDbNetwork]?

    enum CodingKeys: String, CodingKey {
        case id, name, overview, genres, networks
        case originalName = "original_name"
        case firstAirDate = "first_air_date"
        case posterPath = "poster_path"
        case voteAverage = "vote_average"
    }
}

struct TMDbEpisode: Decodable {
    var id: Int?
    var name: String?
    var overview: String?
    var airDate: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var stillPath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, overview
        case airDate = "air_date"
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
        case stillPath = "still_path"
    }
}
