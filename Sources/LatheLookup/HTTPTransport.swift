import Foundation

/// The one seam through which every provider reaches the network.
///
/// Exists so a provider's *logic* — building a request, decoding a response,
/// turning an HTTP status into the right ``LookupError`` — can be tested
/// exhaustively without a key, an account, or a network. Those are the parts
/// that break when an API changes, and they are also the parts that a
/// live-network test exercises least reliably.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real one.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LookupError.transport(provider: "http", detail: "not an HTTP response")
        }
        return (data, http)
    }
}

/// Turns an HTTP status into the error that says what the caller should do.
///
/// Collapsing everything into one "request failed" is what produces support
/// questions: a bad key, an exhausted quota and an unreachable server need three
/// different responses from the user, and the status code already distinguishes
/// them.
enum HTTPStatus {
    static func check(
        _ response: HTTPURLResponse, provider: String, body: Data
    ) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw LookupError.unauthorised(
                provider: provider, detail: Self.detail(body) ?? "status \(response.statusCode)"
            )
        case 429:
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw LookupError.rateLimited(provider: provider, retryAfter: retry)
        default:
            throw LookupError.transport(
                provider: provider,
                detail: Self.detail(body) ?? "status \(response.statusCode)"
            )
        }
    }

    /// The provider's own explanation, when it gave one. Both APIs here return
    /// a JSON body on failure, and it is far more useful than the status.
    private static func detail(_ body: Data) -> String? {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        for key in ["status_message", "message", "error", "errors"] {
            if let text = object[key] as? String { return text }
            if let list = object[key] as? [String], let first = list.first { return first }
        }
        return nil
    }
}
