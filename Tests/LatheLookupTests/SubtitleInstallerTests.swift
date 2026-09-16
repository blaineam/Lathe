import AVFoundation
import Foundation
import LatheFixtures
import LatheMeta
import Testing

@testable import LatheLookup

/// Search, download and inject, end to end, with the network scripted.
///
/// What is asserted is the file that comes out and the requests that went out:
/// the right subtitles in the right tracks, and no more metered downloads than
/// the caller asked for.
@Suite("Subtitle installation", .serialized)
struct SubtitleInstallerTests {

    private static let credentials = ProviderCredentials(apiKey: "SECRET", userAgent: "LatheTests v1")

    private static let search = """
    {"data":[
      {"id":"1","attributes":{"language":"en","download_count":90000,"machine_translated":true,
       "release":"Some.Film.2020.1080p","files":[{"file_id":101,"file_name":"auto.en.srt"}]}},
      {"id":"2","attributes":{"language":"en","download_count":40,"machine_translated":false,
       "release":"Some.Film.2020.720p.WEB","files":[{"file_id":102,"file_name":"other.en.srt"}]}},
      {"id":"3","attributes":{"language":"en","download_count":12,"machine_translated":false,
       "release":"Some.Film.2020.1080p.BluRay","files":[{"file_id":103,"file_name":"match.en.srt"}]}},
      {"id":"4","attributes":{"language":"pt-BR","download_count":5,"hearing_impaired":true,
       "files":[{"file_id":201,"file_name":"film.pt.vtt"}]}}
    ]}
    """

    private static let englishSRT = """
    1
    00:00:00,500 --> 00:00:01,500
    Hello.

    2
    00:00:01,000 --> 00:00:00,900
    This cue runs backwards.

    3
    00:00:02,000 --> 00:00:03,000
    Goodbye.
    """

    private static let portugueseVTT = "WEBVTT\n\n00:01.000 --> 00:02.000\nOlá\n"

    private static func ticket(_ name: String, remaining: Int) -> ScriptedTransport.Reply {
        .init(status: 200, body: Data(
            #"{"link":"https://files.example.com/\#(name)","file_name":"\#(name)","remaining":\#(remaining)}"#.utf8
        ))
    }

    @Test("the best subtitle per language is downloaded once and written into the film")
    func installBest() async throws {
        guard let film = await film("Some.Film.2020.1080p.BluRay.mov") else { return }
        let output = await scratch("installed.m4v")
        let transport = ScriptedTransport([
            .init(status: 200, body: Data(Self.search.utf8)),
            Self.ticket("match.en.srt", remaining: 18),
            .init(status: 200, body: Data(Self.englishSRT.utf8)),
            Self.ticket("film.pt.vtt", remaining: 17),
            .init(status: 200, body: Data(Self.portugueseVTT.utf8)),
        ])
        let installer = SubtitleInstaller(
            provider: OpenSubtitlesProvider(credentials: Self.credentials, transport: transport)
        )

        let result = try await installer.installBest(
            into: film, writingTo: output, languages: ["en", "pt-BR"]
        )

        // The release-matched, human-made English file, not the popular
        // machine translation — and exactly one download per language.
        #expect(result.installed.map(\.fileID) == [103, 201])
        #expect(result.remainingDownloads == 17)
        let requests = await transport.requests
        #expect(requests.count == 5, "one search and two downloads of two requests each")
        let bodies = requests.compactMap(\.httpBody).compactMap { String(data: $0, encoding: .utf8) }
        #expect(bodies.count == 2)
        #expect(bodies.first?.contains("103") == true)
        for request in requests where request.url?.host == "files.example.com" {
            #expect(request.value(forHTTPHeaderField: "Api-Key") == nil, "the key went to the file host")
        }
        let searchURL = try #require(requests.first?.url?.absoluteString)
        #expect(searchURL.contains("query=Some%20Film") || searchURL.contains("query=Some+Film"),
                "the title came from the filename: \(searchURL)")

        // The skipped cue is reported, not silently lost.
        #expect(result.skippedCues.map(\.count) == [1, 0])
        #expect(result.skippedCues.first?.first?.error == .cueEndsBeforeItStarts(line: 6))

        // The file.
        let tracks = try await SubtitleMuxer().subtitleTracks(in: output)
        #expect(tracks.map(\.languageCode) == ["eng", "por"])
        #expect(tracks.map(\.extendedLanguageTag) == ["en", "pt-BR"])
        #expect(tracks.map(\.isHearingImpaired) == [false, true])
        let english = try await SubtitleMuxer().extractCues(from: output, trackID: tracks[0].trackID)
        #expect(english.map(\.text) == ["Hello.", "Goodbye."])
        let portuguese = try await SubtitleMuxer().extractCues(from: output, trackID: tracks[1].trackID)
        #expect(portuguese.map(\.text) == ["Olá"])
    }

    @Test("an unconfigured provider fails before any request and before any file is written")
    func unconfigured() async throws {
        guard let film = await film("unconfigured.mov") else { return }
        let output = await scratch("unconfigured-out.mp4")
        let transport = ScriptedTransport([])
        let installer = SubtitleInstaller(provider: OpenSubtitlesProvider(
            credentials: ProviderCredentials(apiKey: "only-a-key"), transport: transport
        ))
        await #expect(throws: LookupError.self) {
            try await installer.installBest(into: film, writingTo: output)
        }
        #expect(await transport.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("no results in any wanted language is its own error, and costs no download")
    func nothingFound() async throws {
        guard let film = await film("nothing.mov") else { return }
        let transport = ScriptedTransport([.init(status: 200, body: Data(Self.search.utf8))])
        let installer = SubtitleInstaller(
            provider: OpenSubtitlesProvider(credentials: Self.credentials, transport: transport)
        )
        await #expect(throws: SubtitleInstallError.nothingFound(languages: ["de"])) {
            try await installer.installBest(into: film, writingTo: await scratch("nothing-out.mp4"),
                                            languages: ["de"])
        }
        #expect(await transport.requests.count == 1)
        #expect(SubtitleInstallError.nothingFound(languages: ["de"]).recoverySuggestion != nil)
    }

    @Test("a download in a format that cannot be read says so, and writes nothing")
    func unreadableDownload() async throws {
        guard let film = await film("ass.mov") else { return }
        let output = await scratch("ass-out.mp4")
        let transport = ScriptedTransport([
            Self.ticket("film.ass", remaining: 3),
            .init(status: 200, body: Data("[Script Info]\nTitle: x\n".utf8)),
        ])
        let installer = SubtitleInstaller(
            provider: OpenSubtitlesProvider(credentials: Self.credentials, transport: transport)
        )
        await #expect(throws: SubtitleError.unsupportedFormat(.substationAlpha)) {
            try await installer.install(
                [SubtitleCandidate(fileID: 9, fileName: "film.ass", language: "en")],
                into: film, writingTo: output
            )
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("candidates rank human over machine, then this release, then popularity")
    func ranking() {
        let candidates = [
            SubtitleCandidate(fileID: 1, fileName: "a.srt", language: "en", downloadCount: 1_000,
                              isMachineTranslated: true, releaseName: "Film.2020.1080p.BluRay"),
            SubtitleCandidate(fileID: 2, fileName: "b.srt", language: "en", downloadCount: 500),
            SubtitleCandidate(fileID: 3, fileName: "c.srt", language: "en", downloadCount: 5,
                              releaseName: "film 2020 1080p bluray"),
            SubtitleCandidate(fileID: 4, fileName: "d.srt", language: "en", downloadCount: 900),
        ]
        let ranked = SubtitleInstaller.rank(
            candidates, forFile: URL(fileURLWithPath: "/m/Film.2020.1080p.BluRay.mkv")
        )
        #expect(ranked.map(\.fileID) == [3, 4, 2, 1])
        #expect(SubtitleInstaller.trackLanguage("pt-BR") == "pt-BR")
        #expect(SubtitleInstaller.trackLanguage("??") == "und")
    }

    /// `SubtitleFormat` moved to LatheMeta; the alias keeps LatheLookup's
    /// spelling of it the same type.
    @Test("LatheLookup's SubtitleFormat is LatheMeta's")
    func formatAlias() {
        let viaLookup: LatheLookup.SubtitleFormat = .webVTT
        let viaMeta: LatheMeta.SubtitleFormat = viaLookup
        #expect(viaMeta == .webVTT)
    }

    // MARK: - Helpers

    private func film(_ name: String) async -> URL? {
        do {
            return try await FixtureLibrary.shared.movie(named: name, seconds: 4)
        } catch {
            withKnownIssue("could not generate the fixture \"\(name)\" on this machine: \(error)") {
                Issue.record("fixture generation failed")
            }
            return nil
        }
    }

    private func scratch(_ name: String) async -> URL {
        let url = await FixtureLibrary.shared.scratchURL(named: name)
        try? FileManager.default.removeItem(at: url)
        return url
    }
}
