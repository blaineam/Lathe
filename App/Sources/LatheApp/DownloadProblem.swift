import Foundation

/// Something that went wrong with one download, said in a way somebody can act
/// on.
///
/// Its own type rather than reusing `LatheError.notImplemented`, which was the
/// nearest-looking case and produced sentences like "gallery-dl downloaded
/// nothing from www.furaffinity.net — it recognised the site but the page had
/// nothing on it **is not implemented yet**". Borrowing an error case for its
/// shape rather than its meaning always reads like that eventually.
enum DownloadProblem: LocalizedError {

    /// The extractor ran, understood the site, and came back with nothing.
    case nothingFound(host: String, detail: String?, needsSignIn: Bool)

    /// No extractor is installed that can handle this.
    case noExtractor(host: String)

    /// Everything on offer is in a form we cannot put in the container we were
    /// going to write.
    case unusableFormats(host: String, detail: String)

    case cancelled

    var errorDescription: String? {
        switch self {
        case let .nothingFound(host, detail, needsSignIn):
            var message = "Nothing was downloaded from \(host)."
            if let detail, !detail.isEmpty { message += " \(detail)" }
            if needsSignIn {
                // The overwhelmingly common cause on a site that recognises
                // the URL and then returns an empty page. Saying it plainly
                // beats making somebody guess which of a dozen things it was.
                message += " This site shows most of its content only to "
                    + "signed-in visitors — open it in Browse, sign in, and "
                    + "download it from there."
            }
            return message

        case let .noExtractor(host):
            return "\(host) needs an extractor. Install yt-dlp or gallery-dl "
                + "from the banner on the Downloads tab, or paste a direct "
                + "link to a media file."

        case let .unusableFormats(host, detail):
            return "\(host): \(detail)"

        case .cancelled:
            return "Cancelled."
        }
    }
}

/// Sites that answer with an empty page rather than an error when you are not
/// signed in.
///
/// A short, honest list rather than a guess dressed up as detection: these are
/// the ones where "recognised the site, found nothing" almost always means
/// "not signed in", and telling somebody that directly saves them the half
/// hour of assuming the downloader is broken.
enum SignInLikely {
    private static let hosts = [
        "furaffinity.net", "deviantart.com", "pixiv.net", "instagram.com",
        "twitter.com", "x.com", "patreon.com", "fanbox.cc", "tumblr.com",
        "reddit.com", "weibo.com", "inkbunny.net", "e621.net", "newgrounds.com",
    ]

    static func matches(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return hosts.contains { lowered == $0 || lowered.hasSuffix(".\($0)") }
    }
}
