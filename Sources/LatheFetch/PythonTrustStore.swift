import Foundation

/// The certificate authorities Python's TLS verifies against.
///
/// ## The problem this solves, and why it is not obvious
///
/// The OpenSSL inside an embedded CPython has **no CA bundle**. It was built
/// against paths that do not exist inside an application sandbox, and nothing in
/// an iOS or macOS application bundle supplies them. So every Python-side HTTPS
/// request fails certificate verification:
///
/// ```text
/// ssl.SSLCertVerificationError: [SSL: CERTIFICATE_VERIFY_FAILED] certificate
/// verify failed: unable to get local issuer certificate
/// ```
///
/// This is the *good* failure mode — it fails closed, not open — but it means
/// that a package which reaches the network does not work at all until a trust
/// store is supplied.
///
/// Swift's own `URLSession` is unaffected. It uses the system trust store
/// through Security.framework and never consults OpenSSL, which is why this
/// package's own downloads have always worked while Python's would not have.
///
/// ## The chicken and the egg, and the way out
///
/// The obvious source of a CA bundle is `certifi`, which is Mozilla's root store
/// packaged as a pure-Python wheel — exactly the kind of thing
/// ``PythonPackageInstaller`` installs. But fetching it needs TLS, and TLS is
/// what is missing.
///
/// The circle is not real, and the reason is the paragraph above: **Swift fetches
/// it, Python never does.** The wheel is downloaded by `URLSession` against the
/// system trust store, checked against the SHA-256 the index publishes, and only
/// then unpacked by the interpreter. The interpreter's own TLS is not involved
/// at any point in acquiring the thing that will fix the interpreter's TLS.
///
/// Nothing is vendored: no certificate travels with Lathe, and the bundle is
/// Mozilla's, fetched by the user, on their device, into their container — the
/// same position every other installed package is in. It is also the right place
/// for it to live, because a CA bundle that shipped inside a library would go
/// stale on the library's release schedule rather than on Mozilla's.
///
/// ## Using it
///
/// ```swift
/// // First launch: fetch it, then point the running interpreter at it.
/// let store = try await packages.installTrustStore()
/// try runtime.useTrustStore(store)
///
/// // Later launches: it is already on disk, so it can be set before the
/// // interpreter starts.
/// var configuration = try PythonRuntime.Configuration.discovered()
/// configuration.trustStore = PythonTrustStore.installed(in: packageRoot)
/// let runtime = try PythonRuntime.bootstrap(configuration)
/// ```
///
/// ## What it does not do
///
/// It does not make TLS verification *happen* — OpenSSL already verifies, and
/// refuses everything, without it. It supplies the anchors that let a genuine
/// certificate chain succeed. A store that was configured but not enforced would
/// be worse than none at all, because it would look correct; that is why the
/// suite's trust-store test asserts an untrusted certificate is **rejected**
/// with the store in place, and not merely that a good one is accepted.
public struct PythonTrustStore: Sendable, Equatable {

    /// The PEM bundle. Every certificate in it is trusted as a root.
    public let bundle: URL

    /// How many `BEGIN CERTIFICATE` blocks the file holds. Reported rather than
    /// asserted: it is the number that tells a reader at a glance whether this
    /// is Mozilla's store (~150) or a single test certificate (1).
    public let certificateCount: Int

    /// - Throws: ``PythonPackageError/storeUnwritable(path:reason:)`` when the
    ///   file is missing or holds no certificate. Checked on construction
    ///   because the alternative is a `SSLCertVerificationError` from inside
    ///   somebody else's package, which reads as a network problem and is not
    ///   one.
    public init(bundle: URL) throws {
        guard let text = try? String(contentsOf: bundle, encoding: .utf8) else {
            throw PythonPackageError.storeUnwritable(
                path: bundle.path, reason: "there is no readable CA bundle there")
        }
        let count = text.components(separatedBy: "-----BEGIN CERTIFICATE-----").count - 1
        guard count > 0 else {
            throw PythonPackageError.storeUnwritable(
                path: bundle.path, reason: "the file contains no PEM certificate")
        }
        self.bundle = bundle
        self.certificateCount = count
    }

    /// The variables that point an interpreter at this bundle.
    ///
    /// `SSL_CERT_FILE` is what OpenSSL itself reads, and covers `ssl`, `http`,
    /// `urllib` and everything built on them. `REQUESTS_CA_BUNDLE` is read by
    /// `requests`, which otherwise uses the `certifi` it imports rather than the
    /// one configured here — a distinction that matters precisely when both are
    /// present and they disagree.
    public var environment: [String: String] {
        [
            "SSL_CERT_FILE": bundle.path,
            "REQUESTS_CA_BUNDLE": bundle.path,
        ]
    }

    /// The bundle `certifi` installs, if it has been installed into `root`.
    ///
    /// - Returns: `nil` when it has not, which is the ordinary state on a first
    ///   launch and a reason to call ``PythonPackageInstaller/installTrustStore(using:session:)``
    ///   rather than an error.
    public static func installed(in root: URL) -> PythonTrustStore? {
        try? PythonTrustStore(
            bundle: root.appendingPathComponent("certifi", isDirectory: true)
                .appendingPathComponent("cacert.pem"))
    }

    /// The project that publishes the bundle. Named once, here, rather than as a
    /// string literal at the two call sites that need it.
    public static let sourceProject = "certifi"
}

extension PythonPackageInstaller {

    /// Fetches `certifi` and returns its CA bundle.
    ///
    /// The download is Swift's, against the **system** trust store, so this
    /// works on an interpreter whose own TLS does not — which is the whole
    /// point, and the reason this is not simply
    /// `install(requirement: "certifi")` in the caller's own code.
    ///
    /// Idempotent and cheap on later launches: an already-installed `certifi`
    /// is used as it is rather than refetched.
    ///
    /// - Parameter update: `true` re-resolves against the index even when a
    ///   bundle is already installed. Worth doing periodically — a root store
    ///   is a security artefact with an expiry, and an application that never
    ///   updates it will eventually fail to verify perfectly good certificates.
    @discardableResult
    public func installTrustStore(
        update: Bool = false,
        using source: any PythonPackageSource = PyPIPackageSource(),
        session: URLSession = .shared
    ) async throws -> PythonTrustStore {
        if !update, let existing = PythonTrustStore.installed(in: root) {
            return existing
        }
        _ = try await install(requirement: PythonTrustStore.sourceProject, using: source, session: session)
        guard let store = PythonTrustStore.installed(in: root) else {
            throw PythonPackageError.storeUnwritable(
                path: root.path,
                reason: "\(PythonTrustStore.sourceProject) installed but did not write cacert.pem, so "
                    + "there is no CA bundle to point the interpreter at")
        }
        LatheFetchLog.packages.notice(
            "CA bundle ready: \(store.certificateCount, privacy: .public) root certificates")
        return store
    }
}
