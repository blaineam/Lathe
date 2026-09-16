import Foundation
import LatheCore
import LatheMeta

/// A source of metadata about media the user already has.
///
/// ## The rule about keys
///
/// **No third-party API key ships in a binary.** The user supplies their own,
/// and that is a design rule rather than an accommodation:
///
/// - A shipped key is one key for every installation, so it is rate-limited by
///   strangers and revoked because of what a stranger did.
/// - It puts the commercial-use question on whoever compiled the binary rather
///   than on the person who agreed to the provider's terms.
/// - It cannot be kept secret. A key in an app is a key in the app's bundle.
///
/// So a provider with no credentials is **not an error state** — it is the
/// normal state of a fresh install, and everything above it has to keep working
/// without one. Manual metadata editing is the feature; lookup is an
/// accelerator for it.
public protocol MetadataProvider: Sendable {

    /// What to call this provider in a settings screen or an error.
    var name: String { get }

    /// Whether the user has supplied what this provider needs. `false` is an
    /// ordinary state, not a failure.
    var isConfigured: Bool { get }

    /// What this provider needs the user to supply, in words a settings screen
    /// can show — including where to get it.
    var credentialRequirement: String { get }

    /// Candidate matches for a query, best first.
    ///
    /// Returns candidates rather than an answer. Matching a file to a title is a
    /// guess, and a wrong guess applied silently is worse than no guess at all:
    /// it renames a file convincingly. The user confirms, which is also what
    /// makes correcting a mismatch a normal action rather than a recovery.
    func search(_ query: LookupQuery) async throws -> [MetadataMatch]

    /// The full metadata for one match, ready to write.
    func details(for match: MetadataMatch) async throws -> MediaMetadata

    /// The bytes of a match's artwork, if it has any.
    func artwork(for match: MetadataMatch, size: ArtworkSize) async throws -> Artwork?
}

/// What is being looked up.
///
/// Built either from a filename — see ``MediaTitleParser`` — or from what a user
/// typed when correcting a mismatch.
public struct LookupQuery: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case movie
        case episode(season: Int?, episode: Int?)
        /// Search both, which is what a filename that gave up no season or
        /// episode number honestly justifies.
        case unknown
    }

    /// The title to search for, with release noise already removed.
    public var title: String
    /// A release year, which is the single most effective disambiguator between
    /// a remake and the film it remade.
    public var year: Int?
    public var kind: Kind
    /// A BCP-47 language for the returned text, not for the media.
    public var language: String

    public init(title: String, year: Int? = nil, kind: Kind = .unknown, language: String = "en-US") {
        self.title = title
        self.year = year
        self.kind = kind
        self.language = language
    }
}

/// One candidate answer.
public struct MetadataMatch: Sendable, Equatable, Identifiable {
    /// The provider's own identifier, namespaced by provider so two providers'
    /// identifiers can sit in the same ``MediaMetadata/identifiers`` map without
    /// colliding.
    public var id: String
    /// Which provider produced this, so a correction can go back to the same one.
    public var provider: String
    /// The provider's raw identifier, without the namespace.
    public var providerID: String

    public var title: String
    public var year: Int?
    public var overview: String?
    public var kind: MediaKind?

    /// Season and episode, when the match is an episode.
    public var season: Int?
    public var episode: Int?

    /// Where the provider keeps this match's artwork. Opaque — it is the
    /// provider's own reference, resolved by ``MetadataProvider/artwork(for:size:)``.
    public var artworkReference: String?

    /// How confident the provider is, normalised to 0…1, or `nil` when it does
    /// not say. Used to order candidates, never to pick one.
    public var confidence: Double?

    public init(
        provider: String,
        providerID: String,
        title: String,
        year: Int? = nil,
        overview: String? = nil,
        kind: MediaKind? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        artworkReference: String? = nil,
        confidence: Double? = nil
    ) {
        self.id = "\(provider):\(providerID)"
        self.provider = provider
        self.providerID = providerID
        self.title = title
        self.year = year
        self.overview = overview
        self.kind = kind
        self.season = season
        self.episode = episode
        self.artworkReference = artworkReference
        self.confidence = confidence
    }
}

/// How large a poster to fetch.
///
/// Named by intent rather than by pixels, because every provider has its own
/// size vocabulary and a caller asking for "the one that goes in a file" should
/// not have to know theirs.
public enum ArtworkSize: Sendable, Equatable, CaseIterable {
    /// Small enough for a list. Not what you embed.
    case thumbnail
    /// The default for embedding: large enough to look right full-screen on a
    /// television, small enough not to dominate the file it is embedded in.
    case embedded
    /// The largest the provider offers.
    case original
}

/// What the user must supply for a provider to work.
///
/// A struct rather than a bare string because OpenSubtitles needs two things,
/// and discovering that at the HTTP layer produces a 403 rather than an
/// explanation.
public struct ProviderCredentials: Sendable, Equatable {
    /// The user's own API key.
    public var apiKey: String?

    /// A `User-Agent` identifying the application.
    ///
    /// OpenSubtitles requires one that is **registered with them per
    /// application**, which is not the same thing as the user's API key: a
    /// correct key with an unregistered agent is still refused. That makes it a
    /// question for whoever ships the integration rather than for the user, and
    /// it is the thing most likely to make an otherwise-correct setup fail.
    public var userAgent: String?

    public init(apiKey: String? = nil, userAgent: String? = nil) {
        self.apiKey = apiKey
        self.userAgent = userAgent
    }

    public var hasKey: Bool { !(apiKey ?? "").isEmpty }
}

/// What goes wrong with a lookup, separated by what the caller should do next.
/// What goes wrong with a lookup.
///
/// `LocalizedError` as well as `CustomStringConvertible`, and the conformance
/// is not decoration: an `Error` without it reports through
/// `localizedDescription` as "The operation couldn't be completed.
/// (LatheLookup.LookupError error 4.)" — a case index, in an alert, in front
/// of somebody who now has to count enum cases to find out that their app
/// could not reach the network.
public enum LookupError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// No key. The caller should offer to configure one, not report a failure.
    case notConfigured(provider: String, requirement: String)
    /// The provider rejected the credentials.
    case unauthorised(provider: String, detail: String)
    /// The provider asked us to slow down. `retryAfter` is its own advice, when
    /// it gave any.
    case rateLimited(provider: String, retryAfter: TimeInterval?)
    /// The provider answered, and the answer was not what this code expects —
    /// which usually means the API changed.
    case malformedResponse(provider: String, detail: String)
    /// The network, or the provider, failed.
    case transport(provider: String, detail: String)
    /// The query had nothing usable in it.
    case emptyQuery

    public var description: String {
        switch self {
        case .notConfigured(let provider, let requirement):
            return "\(provider) is not configured: \(requirement)"
        case .unauthorised(let provider, let detail):
            return "\(provider) rejected the credentials: \(detail)"
        case .rateLimited(let provider, let retryAfter):
            let when = retryAfter.map { " (retry after \(Int($0))s)" } ?? ""
            return "\(provider) is rate limiting this key\(when)"
        case .malformedResponse(let provider, let detail):
            return "\(provider) returned something unexpected: \(detail)"
        case .transport(let provider, let detail):
            return "could not reach \(provider): \(detail)"
        case .emptyQuery:
            return "nothing to search for"
        }
    }

    public var errorDescription: String? { description }

    /// What the person reading this can actually do about it.
    public var recoverySuggestion: String? {
        switch self {
        case .notConfigured(_, let requirement):
            return "Add \(requirement)."
        case .unauthorised:
            return "Check the key, and that it is the right one of the two the "
                + "provider issues — an API key and a read access token are not "
                + "interchangeable."
        case .rateLimited:
            return "Wait a little and try again."
        case .malformedResponse:
            return "This usually means the provider changed its API."
        case .transport:
            return "Check the network connection. A sandboxed application also "
                + "needs the outgoing-connections entitlement, without which "
                + "every request fails here no matter what the credentials are."
        case .emptyQuery:
            return "Type something to search for."
        }
    }
}
