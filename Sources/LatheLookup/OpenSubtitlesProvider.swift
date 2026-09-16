import Foundation
import LatheCore
import LatheMeta

/// Subtitles from OpenSubtitles, using the user's own API key.
///
/// ## Two credentials, not one — and the second is not the user's
///
/// OpenSubtitles requires a `User-Agent` that identifies the **application** and
/// is registered with them. A correct user API key with an unregistered agent is
/// still refused, which makes this the thing most likely to break an otherwise
/// correct setup, and it is not something the user can fix by pasting a key.
///
/// So it is a question for whoever ships an integration: register the
/// application once, and pass the agent in ``ProviderCredentials/userAgent``.
/// ``isConfigured`` is false without it, and the requirement says so in words,
/// rather than the user meeting a 403 with no explanation.
///
/// > Important: this is stated from the API's published requirements and has not
/// > been exercised against the live service from this repository, because doing
/// > so needs a registered agent and a key. Treat the agent requirement as the
/// > first thing to check if a real integration returns 403 with a valid key.
///
/// ## Downloading is two requests, and the second is quota'd
///
/// A search returns file identifiers, not files. Turning one into subtitle text
/// costs a `download` call, which is metered per key per day — so a caller that
/// downloads every candidate to show the user a preview will exhaust a user's
/// quota on one film. ``download(_:)`` is deliberately separate from
/// ``search(_:)`` for that reason.
public struct OpenSubtitlesProvider: Sendable {

    public let name = "OpenSubtitles"

    public var credentialRequirement: String {
        "an OpenSubtitles API key from opensubtitles.com, and a User-Agent "
            + "registered with them for this application — both are required"
    }

    private let credentials: ProviderCredentials
    private let transport: any HTTPTransport
    private let baseURL: URL

    public init(
        credentials: ProviderCredentials,
        transport: any HTTPTransport = URLSessionTransport(),
        baseURL: URL = URL(string: "https://api.opensubtitles.com/api/v1")!
    ) {
        self.credentials = credentials
        self.transport = transport
        self.baseURL = baseURL
    }

    /// Both credentials, not just the key.
    public var isConfigured: Bool {
        credentials.hasKey && !(credentials.userAgent ?? "").isEmpty
    }

    // MARK: - Searching

    public func search(_ query: SubtitleQuery) async throws -> [SubtitleCandidate] {
        guard isConfigured else {
            throw LookupError.notConfigured(provider: name, requirement: credentialRequirement)
        }
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || query.imdbID != nil else { throw LookupError.emptyQuery }

        var items: [URLQueryItem] = []
        if let imdb = query.imdbID {
            // An identifier beats a title every time: it removes the remake
            // problem entirely rather than ranking around it.
            items.append(URLQueryItem(name: "imdb_id", value: imdb.replacingOccurrences(of: "tt", with: "")))
        } else {
            items.append(URLQueryItem(name: "query", value: title))
        }
        if !query.languages.isEmpty {
            items.append(URLQueryItem(name: "languages", value: query.languages.joined(separator: ",")))
        }
        if let season = query.season {
            items.append(URLQueryItem(name: "season_number", value: String(season)))
        }
        if let episode = query.episode {
            items.append(URLQueryItem(name: "episode_number", value: String(episode)))
        }
        if query.hearingImpairedOnly {
            items.append(URLQueryItem(name: "hearing_impaired", value: "only"))
        }

        let payload: OSSearchResponse = try await get("/subtitles", items)
        return payload.data.compactMap(Self.candidate(from:))
    }

    static func candidate(from item: OSSubtitleItem) -> SubtitleCandidate? {
        guard let attributes = item.attributes,
              let file = attributes.files?.first,
              let fileID = file.fileID
        else { return nil }
        return SubtitleCandidate(
            fileID: fileID,
            fileName: file.fileName ?? "subtitle.srt",
            language: attributes.language ?? "und",
            downloadCount: attributes.downloadCount,
            rating: attributes.ratings,
            isHearingImpaired: attributes.hearingImpaired ?? false,
            isMachineTranslated: attributes.machineTranslated ?? false,
            releaseName: attributes.release
        )
    }

    // MARK: - Downloading

    /// Fetches one candidate's text. Costs a metered download from the user's
    /// daily quota — see the type's note.
    public func download(_ candidate: SubtitleCandidate) async throws -> SubtitleDocument {
        guard isConfigured else {
            throw LookupError.notConfigured(provider: name, requirement: credentialRequirement)
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("/download"))
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["file_id": candidate.fileID]
        )

        let (data, _) = try await sendChecked(request)
        let ticket: OSDownloadTicket
        do {
            ticket = try JSONDecoder().decode(OSDownloadTicket.self, from: data)
        } catch {
            throw LookupError.malformedResponse(provider: name, detail: String(describing: error))
        }
        guard let link = ticket.link, let url = URL(string: link) else {
            throw LookupError.malformedResponse(provider: name, detail: "the download ticket had no link")
        }

        // The link is a plain file URL and must NOT carry the API key: it is a
        // pre-signed address, and attaching credentials to it would send them
        // to a host that never needed them.
        let (body, _) = try await sendChecked(URLRequest(url: url))
        guard !body.isEmpty else {
            throw LookupError.malformedResponse(provider: name, detail: "the download was empty")
        }

        return SubtitleDocument(
            data: body,
            format: SubtitleFormat(filename: ticket.fileName ?? candidate.fileName, contents: body),
            language: candidate.language,
            remainingDownloads: ticket.remaining
        )
    }

    // MARK: - Plumbing

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue(credentials.apiKey ?? "", forHTTPHeaderField: "Api-Key")
        request.setValue(credentials.userAgent ?? "", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func get<T: Decodable>(_ path: String, _ items: [URLQueryItem]) async throws -> T {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false
        ) else {
            throw LookupError.transport(provider: name, detail: "could not build a URL for \(path)")
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else {
            throw LookupError.transport(provider: name, detail: "could not build a URL for \(path)")
        }

        var request = URLRequest(url: url)
        applyHeaders(to: &request)

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
}

/// What subtitles are being looked for.
public struct SubtitleQuery: Sendable, Equatable {
    public var title: String
    /// An IMDb identifier, when one is known — from a TMDb lookup, say. It
    /// removes the remake problem entirely rather than ranking around it.
    public var imdbID: String?
    public var season: Int?
    public var episode: Int?
    /// BCP-47 language codes, most wanted first.
    public var languages: [String]
    public var hearingImpairedOnly: Bool

    public init(
        title: String,
        imdbID: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        languages: [String] = ["en"],
        hearingImpairedOnly: Bool = false
    ) {
        self.title = title
        self.imdbID = imdbID
        self.season = season
        self.episode = episode
        self.languages = languages
        self.hearingImpairedOnly = hearingImpairedOnly
    }

    /// The subtitle query implied by a media lookup, so the two are not
    /// described twice by the caller.
    public init(_ query: LookupQuery, imdbID: String? = nil, languages: [String] = ["en"]) {
        var season: Int?
        var episode: Int?
        if case .episode(let s, let e) = query.kind { season = s; episode = e }
        self.init(
            title: query.title, imdbID: imdbID, season: season, episode: episode,
            languages: languages
        )
    }
}

/// One subtitle file on offer. Downloading it is a separate, metered step.
public struct SubtitleCandidate: Sendable, Equatable, Identifiable {
    public var id: Int { fileID }
    public var fileID: Int
    public var fileName: String
    public var language: String
    public var downloadCount: Int?
    public var rating: Double?
    public var isHearingImpaired: Bool
    /// Machine-translated subtitles are frequently unusable, and the API marks
    /// them, so a caller can rank or hide them rather than discovering it after
    /// spending a download.
    public var isMachineTranslated: Bool
    /// The release the subtitle was timed against. The single best predictor of
    /// whether it will be in sync.
    public var releaseName: String?

    public init(
        fileID: Int,
        fileName: String,
        language: String,
        downloadCount: Int? = nil,
        rating: Double? = nil,
        isHearingImpaired: Bool = false,
        isMachineTranslated: Bool = false,
        releaseName: String? = nil
    ) {
        self.fileID = fileID
        self.fileName = fileName
        self.language = language
        self.downloadCount = downloadCount
        self.rating = rating
        self.isHearingImpaired = isHearingImpaired
        self.isMachineTranslated = isMachineTranslated
        self.releaseName = releaseName
    }
}

/// A downloaded subtitle.
public struct SubtitleDocument: Sendable, Equatable {
    public var data: Data
    public var format: SubtitleFormat
    public var language: String
    /// How many downloads the user's key has left today, when the API said.
    /// Worth surfacing: the limit is low enough that a user can hit it.
    public var remainingDownloads: Int?

    public init(data: Data, format: SubtitleFormat, language: String, remainingDownloads: Int? = nil) {
        self.data = data
        self.format = format
        self.language = language
        self.remainingDownloads = remainingDownloads
    }

    /// The text, decoded.
    ///
    /// Subtitles in the wild are frequently Latin-1 or Windows-1252 rather than
    /// UTF-8 — a file that is mostly ASCII with a few accented characters
    /// decodes as UTF-8 right up until it does not — so the fallbacks are tried
    /// rather than the decode being allowed to fail.
    public var text: String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }
}

// MARK: - Wire types

struct OSSearchResponse: Decodable {
    var data: [OSSubtitleItem]
}

struct OSSubtitleItem: Decodable {
    var id: String?
    var attributes: OSAttributes?
}

struct OSAttributes: Decodable {
    var language: String?
    var downloadCount: Int?
    var ratings: Double?
    var hearingImpaired: Bool?
    var machineTranslated: Bool?
    var release: String?
    var files: [OSFile]?

    enum CodingKeys: String, CodingKey {
        case language, ratings, release, files
        case downloadCount = "download_count"
        case hearingImpaired = "hearing_impaired"
        case machineTranslated = "machine_translated"
    }
}

struct OSFile: Decodable {
    var fileID: Int?
    var fileName: String?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileName = "file_name"
    }
}

struct OSDownloadTicket: Decodable {
    var link: String?
    var fileName: String?
    var requests: Int?
    var remaining: Int?

    enum CodingKeys: String, CodingKey {
        case link, requests, remaining
        case fileName = "file_name"
    }
}
