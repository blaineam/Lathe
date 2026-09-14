import Foundation
import Testing

@testable import LatheFetch

/// The JavaScript runtime that stands in for the subprocess `yt-dlp` cannot
/// start.
///
/// Everything except the last test is offline: `JavaScriptCore` is a system
/// framework, so the engine itself can be exercised completely without a
/// network. The last one fetches a real YouTube player and solves real
/// challenges with it, which is the only way to find out whether the *solver*
/// still runs — and is therefore opt-in.
@Suite("JavaScriptCore stands in for the external JS runtime")
struct JavaScriptEngineTests {

    @Test("the engine is present on this platform")
    func isAvailable() {
        // Probed rather than version-gated, the same rule the image module's
        // capability check follows. JavaScriptCore is a system framework on
        // both platforms, so this is expected to be true everywhere — but
        // "expected" is not "asserted from a version number".
        #expect(JavaScriptEngine.isAvailable)
    }

    @Test("console.log is the result channel")
    func capturesConsoleLog() throws {
        // The solver's last statement is `console.log(JSON.stringify(...))`, so
        // capturing that *is* the return value. A bare JSContext has no console
        // at all.
        let evaluation = try JavaScriptEngine.evaluate(
            "console.log(JSON.stringify({answer: 6 * 7}));")
        #expect(evaluation.succeeded)
        #expect(evaluation.output == #"{"answer":42}"#)
    }

    @Test("warn and error are installed too, and kept apart from the result")
    func separatesDiagnostics() throws {
        let evaluation = try JavaScriptEngine.evaluate(
            """
            console.warn("a warning");
            console.error("a problem");
            console.log("the answer");
            """)
        #expect(evaluation.output == "the answer", "diagnostics must not pollute the result channel")
        #expect(evaluation.diagnostics.contains("a warning"))
        #expect(evaluation.diagnostics.contains("a problem"))
    }

    @Test("an uncaught exception is data, not a thrown Swift error")
    func exceptionsAreData() throws {
        // The caller is a yt-dlp provider that has to turn a failure into a
        // rejected challenge. A thrown Swift error would only have to be caught
        // and converted back.
        let evaluation = try JavaScriptEngine.evaluate("throw new Error('deliberate');")
        #expect(!evaluation.succeeded)
        #expect(evaluation.exception?.contains("deliberate") == true)
    }

    @Test("a syntax error is reported rather than crashing")
    func syntaxErrors() throws {
        let evaluation = try JavaScriptEngine.evaluate("function ( { { {")
        #expect(!evaluation.succeeded)
        #expect(evaluation.exception != nil)
    }

    @Test("each evaluation gets a fresh global, so nothing leaks between solves")
    func isolatesEvaluations() throws {
        _ = try JavaScriptEngine.evaluate("globalThis.smuggled = 'here';")
        let second = try JavaScriptEngine.evaluate(
            "console.log(typeof globalThis.smuggled);")
        #expect(second.output == "undefined")
    }

    @Test("the browser globals the solver stubs for itself are absent, as it expects")
    func hasNoBrowserGlobals() throws {
        // The solver guards its own stubs with `typeof x === "undefined"`, so a
        // bare context is exactly what it wants. Asserting the bareness is
        // asserting that it will take its own path.
        let evaluation = try JavaScriptEngine.evaluate(
            """
            console.log(JSON.stringify([
              typeof document, typeof window, typeof XMLHttpRequest, typeof navigator
            ]));
            """)
        #expect(evaluation.output == #"["undefined","undefined","undefined","undefined"]"#)
    }

    @Test("a big program parses and runs, which is the whole workload")
    func handlesLargePrograms() throws {
        // The real solver input is a ~3 MB minified player plus the solver
        // bundle. A context that choked on size would be no use, and the
        // failure would only show up against a live player.
        let filler = String(repeating: "var x = 1; ", count: 120_000)
        let evaluation = try JavaScriptEngine.evaluate(filler + "console.log('done');")
        #expect(evaluation.succeeded, "\(evaluation.exception ?? "")")
        #expect(evaluation.output == "done")
        print("  evaluated \(filler.count / 1024) KiB of JavaScript in \(evaluation.duration)s")
    }

    @Test("the timing surface reports something usable")
    func reportsTiming() throws {
        // The number this exists to produce is the interpreter-only cost of a
        // real signature solve on a real device; see the table on
        // JavaScriptEngine. This only checks the instrument works.
        let timings = try JavaScriptEngine.benchmark(
            "var t = 0; for (var i = 0; i < 2000000; i++) { t += i; } console.log(t);",
            iterations: 3)
        #expect(timings.count == 3)
        #expect(timings.allSatisfy { $0 > 0 })
        let formatted = timings.map { String(format: "%.3f", $0) }.joined(separator: ", ")
        print("  2M-iteration loop, three runs: \(formatted) s")
    }

    // MARK: - The address handed to Python

    @Test("the function addresses are real, non-zero pointers")
    func exportsAddresses() {
        // Python rebuilds callables from these with ctypes.CFUNCTYPE. A zero
        // here would be a segmentation fault inside the interpreter rather than
        // an error anyone could catch, which is why it is checked on this side.
        for address in [
            JavaScriptBridge.evaluateAddress, JavaScriptBridge.freeAddress,
            ProgressBridge.callbackAddress,
        ] {
            let value = UInt(address)
            #expect(value != nil, "\(address) is not a number")
            #expect((value ?? 0) > 0)
        }
    }

    // MARK: - Against the real thing (network, opt-in)

    @Test(
        "JavaScriptCore solves a real YouTube signature challenge",
        .enabled(if: SharedInterpreter.networkTestsEnabled && SharedInterpreter.isAvailable))
    func solvesRealChallenges() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-jsc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = PythonPackageInstaller(runtime: runtime, root: root)
        let store = try await installer.installTrustStore()
        try runtime.useTrustStore(store)
        _ = try await installer.install(requirement: "yt-dlp-ejs")
        try await installer.activate()

        // The solver bundle, straight out of the installed package. This is the
        // same pair of scripts yt-dlp's own provider would load.
        let scripts = try await runtime.evaluateDetached(
            """
            (lambda solver: __import__("json").dumps({"lib": solver.lib(), "core": solver.core()}))(
                __import__("yt_dlp_ejs.yt.solver", fromlist=["solver"]))
            """)
        struct Scripts: Decodable {
            let lib: String
            let core: String
        }
        let bundle = try #require(scripts.value.string).data(using: .utf8)
        let solver = try JSONDecoder().decode(Scripts.self, from: try #require(bundle))
        print("  solver: lib \(solver.lib.count / 1024) KiB, core \(solver.core.count / 1024) KiB")

        // A real player, fetched by URLSession against the system trust store.
        let playerURL = try await currentPlayerURL()
        var request = URLRequest(url: playerURL)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (playerData, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            withKnownIssue("YouTube would not serve the player") {
                Issue.record("player fetch failed")
            }
            return
        }
        let player = String(decoding: playerData, as: UTF8.self)
        print("  player: \(player.count / 1024) KiB")

        let payload: [String: Any] = [
            "type": "player",
            "player": player,
            "requests": [["type": "n", "challenges": ["iFhfsBvfnUmAYGVuY", "M3lYrbEaXrXAaA-iGY"]]],
            "output_preprocessed": false,
        ]
        let payloadJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)

        // Exactly the program yt-dlp's EJSBaseJCP._construct_stdin builds.
        let program = """
            \(solver.lib)
            Object.assign(globalThis, lib);
            \(solver.core)
            console.log(JSON.stringify(jsc(\(payloadJSON))));
            """
        print("  program: \(program.count / 1024) KiB")

        let evaluation = try JavaScriptEngine.evaluate(program)
        print(String(format: "  solved in %.3f s", evaluation.duration))
        guard evaluation.succeeded else {
            Issue.record("JavaScriptCore could not run the solver: \(evaluation.exception ?? "")")
            return
        }

        struct Solved: Decodable {
            struct Response: Decodable {
                let type: String
                let data: [String: String]?
            }
            let type: String
            let responses: [Response]?
        }
        let solved = try JSONDecoder().decode(
            Solved.self, from: Data(evaluation.output.utf8))
        #expect(solved.type == "result", "the solver reported: \(evaluation.output.prefix(400))")
        let results = try #require(solved.responses?.first?.data)
        #expect(results.count == 2)
        for (challenge, answer) in results {
            #expect(!answer.isEmpty)
            #expect(answer != challenge, "an unchanged challenge means nothing was deciphered")
            print("    \(challenge) → \(answer)")
        }
    }

    /// The id of the player YouTube is currently serving.
    ///
    /// The id has to be read out rather than pinned: YouTube rotates the player
    /// every few days, and a pinned id is a test that passes until it silently
    /// stops testing anything.
    private func currentPlayerURL() async throws -> URL {
        let (data, _) = try await URLSession.shared.data(
            from: URL(string: "https://www.youtube.com/iframe_api")!)
        let body = String(decoding: data, as: UTF8.self)

        // A capture group, not a filter over the match: the literal word
        // "player" contains two hex digits of its own, and filtering for
        // `isHexDigit` quietly prepends them to the id.
        let pattern = try NSRegularExpression(pattern: #"player\\?/([0-9a-fA-F]{8})\\?/"#)
        guard let match = pattern.firstMatch(
            in: body, range: NSRange(body.startIndex..., in: body)),
            let range = Range(match.range(at: 1), in: body)
        else {
            throw MediaFetchError.extractionFailed(reason: "no player id in the iframe API")
        }
        return URL(
            string: "https://www.youtube.com/s/player/\(body[range])/player_ias.vflset/en_US/base.js")!
    }
}
