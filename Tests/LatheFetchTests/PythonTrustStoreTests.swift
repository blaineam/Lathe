import Foundation
import Testing

@testable import LatheFetch

/// Python's TLS trust, and the thing that is easy to get wrong about it.
///
/// A trust store that is *configured* but not *enforced* is worse than none at
/// all, because it looks correct: every request succeeds, including the ones
/// that should not. So the load-bearing test here is not "a good certificate is
/// accepted" — it is **an untrusted certificate is rejected, with the store in
/// place**. Both directions are asserted against a TLS server this suite starts
/// itself, so the whole thing runs offline.
@Suite("Python TLS trust store")
struct PythonTrustStoreTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The value (no interpreter, no network)

    @Test("a bundle that is not a bundle is refused on construction")
    func refusesNonBundles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Missing entirely.
        #expect(throws: PythonPackageError.self) {
            try PythonTrustStore(bundle: directory.appendingPathComponent("absent.pem"))
        }

        // Present, and not a certificate. Caught here rather than surfacing as
        // an SSLCertVerificationError from inside somebody else's package.
        let notPEM = directory.appendingPathComponent("notes.txt")
        try "no certificates in here\n".write(to: notPEM, atomically: true, encoding: .utf8)
        #expect(throws: PythonPackageError.self) { try PythonTrustStore(bundle: notPEM) }
    }

    @Test("a PEM bundle reports how many roots it carries")
    func countsCertificates() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let bundle = directory.appendingPathComponent("cacert.pem")
        let block = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"
        try (block + block + block).write(to: bundle, atomically: true, encoding: .utf8)

        let store = try PythonTrustStore(bundle: bundle)
        #expect(store.certificateCount == 3)
        #expect(store.environment["SSL_CERT_FILE"] == bundle.path)
        #expect(store.environment["REQUESTS_CA_BUNDLE"] == bundle.path)
    }

    @Test("a configured trust store reaches the interpreter's environment, and a caller can still override it")
    func contributesToBootstrapEnvironment() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = directory.appendingPathComponent("cacert.pem")
        try "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"
            .write(to: bundle, atomically: true, encoding: .utf8)

        var configuration = PythonRuntime.Configuration(
            layout: PythonLayout(home: directory, version: "3.13"))
        configuration.trustStore = try PythonTrustStore(bundle: bundle)

        #expect(PythonRuntime.environment(for: configuration)["SSL_CERT_FILE"] == bundle.path)

        // `additionalEnvironment` is documented as applying last. A caller who
        // sets SSL_CERT_FILE by hand means it.
        configuration.additionalEnvironment["SSL_CERT_FILE"] = "/somewhere/else.pem"
        #expect(PythonRuntime.environment(for: configuration)["SSL_CERT_FILE"] == "/somewhere/else.pem")
    }

    @Test("certifi's installed bundle is found where certifi puts it")
    func findsInstalledBundle() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(PythonTrustStore.installed(in: root) == nil)

        let certifi = root.appendingPathComponent("certifi", isDirectory: true)
        try FileManager.default.createDirectory(at: certifi, withIntermediateDirectories: true)
        try "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n"
            .write(to: certifi.appendingPathComponent("cacert.pem"), atomically: true, encoding: .utf8)

        #expect(PythonTrustStore.installed(in: root) != nil)
    }

    // MARK: - Verification, against a real TLS server

    #if os(macOS)

        /// What one connection attempt did.
        private struct Attempt: Decodable {
            let ok: Bool
            let body: String
            let error: String
        }

        private struct Probe: Decodable {
            let defaultAnchors: Attempt
            let explicitAnchor: Attempt
            let environmentAnchor: Attempt
            let emptyAnchor: Attempt

            enum CodingKeys: String, CodingKey {
                case defaultAnchors = "default"
                case explicitAnchor = "explicit"
                case environmentAnchor = "environment"
                case emptyAnchor = "empty"
            }
        }

        /// A self-signed certificate and its key, made with the `openssl` every
        /// Mac has.
        ///
        /// - Returns: `nil` when the tool is missing or refuses, which is a
        ///   reason to skip rather than to fail — the thing under test is
        ///   Python's verification, not the host's OpenSSL.
        private func selfSignedCertificate(in directory: URL) -> (certificate: URL, key: URL)? {
            let certificate = directory.appendingPathComponent("cert.pem")
            let key = directory.appendingPathComponent("key.pem")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = [
                "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", key.path, "-out", certificate.path,
                "-days", "2", "-subj", "/CN=lathe-trust-store-test",
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return nil
            }
            guard process.terminationStatus == 0,
                FileManager.default.isReadableFile(atPath: certificate.path),
                FileManager.default.isReadableFile(atPath: key.path)
            else { return nil }
            return (certificate, key)
        }

        @Test(
            "an untrusted certificate is rejected, and the configured one is accepted",
            .enabled(if: SharedInterpreter.isAvailable))
        func verificationIsEnforced() throws {
            let runtime = try #require(SharedInterpreter.outcome.runtime)
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            guard let material = selfSignedCertificate(in: directory) else {
                withKnownIssue("/usr/bin/openssl could not make a test certificate on this machine") {
                    Issue.record("no self-signed certificate, so TLS verification was not exercised")
                }
                return
            }

            // An anchor file with no anchors in it: valid input to OpenSSL,
            // and trusts nothing. This is what "a trust store that is present
            // but does not contain the issuer" looks like.
            let empty = directory.appendingPathComponent("empty.pem")
            try "".write(to: empty, atomically: true, encoding: .utf8)

            try runtime.execute(Self.probeSource)

            let evaluation = try runtime.evaluate(
                "_lathe_tls_probe(lathe_arguments['cert'], lathe_arguments['key'], lathe_arguments['empty'])",
                arguments: [
                    "cert": material.certificate.path,
                    "key": material.key.path,
                    "empty": empty.path,
                ])
            let probe = try evaluation.value.decode(Probe.self)

            // The one that matters. With the host's ordinary anchors in place,
            // a self-signed certificate must not be accepted — if this passes
            // by accident, every other TLS assertion in this suite is worthless.
            #expect(probe.defaultAnchors.ok == false, "an untrusted certificate was accepted")
            #expect(
                probe.defaultAnchors.error.contains("CERTIFICATE_VERIFY_FAILED")
                    || probe.defaultAnchors.error.contains("SSLCertVerificationError"),
                "rejected, but not for certificate verification: \(probe.defaultAnchors.error)")

            // Trusting it explicitly works, which is what says the server and
            // the client are otherwise fine and the rejection above was about
            // trust rather than about a broken fixture.
            #expect(probe.explicitAnchor.ok, "explicitly trusted certificate: \(probe.explicitAnchor.error)")
            #expect(probe.explicitAnchor.body == "ok")

            // …and the same thing through `SSL_CERT_FILE`, which is the exact
            // mechanism `PythonTrustStore` uses. Without this, the type could be
            // pointing the interpreter at a file it never reads.
            #expect(probe.environmentAnchor.ok, "SSL_CERT_FILE anchor: \(probe.environmentAnchor.error)")

            // And pointing it at a store without the issuer brings the
            // rejection back, so the acceptance above was caused by the file's
            // contents rather than by the variable's presence disabling
            // verification.
            #expect(probe.emptyAnchor.ok == false, "an empty CA bundle accepted an untrusted certificate")
        }

        /// The probe, in Python.
        ///
        /// `check_hostname` is off in every client here on purpose: hostname
        /// matching is a separate check with separate failure modes, and leaving
        /// it on would let a hostname mismatch masquerade as the chain
        /// verification this test is about.
        private static let probeSource = #"""
            def _lathe_tls_probe(cert_path, key_path, empty_path):
                import http.client
                import http.server
                import os
                import ssl
                import threading

                server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                server_context.load_cert_chain(cert_path, key_path)

                class Handler(http.server.BaseHTTPRequestHandler):
                    def do_GET(self):
                        self.send_response(200)
                        self.send_header("Content-Length", "2")
                        self.end_headers()
                        self.wfile.write(b"ok")

                    def log_message(self, *args):
                        pass

                class Server(http.server.HTTPServer):
                    def handle_error(self, request, address):
                        # A refused handshake is the result this test is after,
                        # not an error to report.
                        pass

                server = Server(("127.0.0.1", 0), Handler)
                server.socket = server_context.wrap_socket(server.socket, server_side=True)
                port = server.server_address[1]
                threading.Thread(target=server.serve_forever, daemon=True).start()

                def client():
                    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                    context.check_hostname = False
                    context.verify_mode = ssl.CERT_REQUIRED
                    return context

                def attempt(context):
                    try:
                        connection = http.client.HTTPSConnection(
                            "127.0.0.1", port, context=context, timeout=10)
                        connection.request("GET", "/")
                        body = connection.getresponse().read().decode()
                        connection.close()
                        return {"ok": True, "body": body, "error": ""}
                    except BaseException as exc:
                        return {"ok": False, "body": "", "error": "%s: %s" % (type(exc).__name__, exc)}

                results = {}
                try:
                    context = client()
                    context.load_default_certs()
                    results["default"] = attempt(context)

                    context = client()
                    context.load_verify_locations(cert_path)
                    results["explicit"] = attempt(context)

                    previous = os.environ.get("SSL_CERT_FILE")
                    try:
                        os.environ["SSL_CERT_FILE"] = cert_path
                        context = client()
                        context.load_default_certs()
                        results["environment"] = attempt(context)

                        os.environ["SSL_CERT_FILE"] = empty_path
                        context = client()
                        context.load_default_certs()
                        results["empty"] = attempt(context)
                    finally:
                        if previous is None:
                            os.environ.pop("SSL_CERT_FILE", None)
                        else:
                            os.environ["SSL_CERT_FILE"] = previous
                finally:
                    server.shutdown()
                    server.server_close()

                # Returned as a dict rather than as JSON text: the bridge
                # encodes a value's JSON form itself, and a string of JSON
                # would arrive on the Swift side double-encoded.
                return results
            """#

    #endif

    // MARK: - Fetching the bundle (network, opt-in)

    @Test(
        "certifi installs and gives a usable CA bundle",
        .enabled(if: SharedInterpreter.networkTestsEnabled && SharedInterpreter.isAvailable))
    func installsTrustStore() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = PythonPackageInstaller(runtime: runtime, root: root)
        let store = try await installer.installTrustStore()

        // Mozilla's root store is well over a hundred certificates. A file with
        // one or two in it would mean something else was fetched.
        #expect(store.certificateCount > 50)
        print("  CA bundle: \(store.certificateCount) roots")

        // Fetched by URLSession against the *system* trust store, which is the
        // reason this works at all on an interpreter whose own TLS does not.
        try await installer.activate()
        try runtime.useTrustStore(store)
        #expect(
            try runtime.evaluate("__import__('os').environ['SSL_CERT_FILE']").value.string
                == store.bundle.path)

        // The proof: Python's own HTTPS now verifies a real certificate chain.
        try runtime.execute("import urllib.request")
        let status = try runtime.evaluate("urllib.request.urlopen('https://pypi.org/simple/', timeout=30).status")
        #expect(status.value.int == 200)
    }
}
