import Foundation
import Testing
@testable import HDMCore

@Suite struct MediaResolverTests {
    let page = URL(string: "https://www.oguzbenlioglu.com/products/k/categories/1/posts/2")!
    let wistia = URL(string: "https://fast.wistia.net/embed/iframe/m3m3xookbb")!
    let hls = URL(string: "https://cdn.e.com/master.m3u8")!
    let frame = URL(string: "https://player.e.com/embed/9")!
    let base = ["Cookie": "session=1", "User-Agent": "UA"]

    func info(_ title: String) throws -> YTDLPInfo {
        try JSONDecoder().decode(YTDLPInfo.self, from: Data(#"{"title":"\#(title)","formats":[{"format_id":"hd","ext":"mp4","height":720}]}"#.utf8))
    }

    @Test func candidatesRunPageThenEmbedsThenStreams() {
        let hints = MediaHints(pageURL: page, embeds: [wistia],
                               streams: [.init(url: hls, kind: .hls, frameURL: frame),
                                         .init(url: URL(string: "https://w.com/d.bin")!, kind: .file, frameURL: nil)])
        let list = MediaResolver.candidates(for: hints, headers: base)
        #expect(list.map(\.url) == [page, wistia, hls])
        #expect(list[0].headers == base, "the page keeps the browser cookies")
        #expect(list[1].headers["Referer"] == page.absoluteString, "an embed is fetched as the page would")
        #expect(list[2].headers["Referer"] == frame.absoluteString)
        #expect(list[2].headers["Origin"] == "https://player.e.com")
        #expect(list[2].headers["Cookie"] == "session=1")
    }

    @Test func triesEveryCandidateUntilOneWorks() async throws {
        let expected = try info("Karizma")
        let tried = TriedURLs()
        let outcome = await MediaResolver.resolve(
            MediaResolver.candidates(for: MediaHints(pageURL: page, embeds: [wistia]), headers: base)) { candidate in
                await tried.add(candidate.url)
                if candidate.url == page { throw MediaQueryError.failed("Unable to extract video") }
                return expected
            }
        #expect(await tried.urls == [page, wistia])
        guard case .success(let found) = outcome else { Issue.record("expected success, got \(outcome)"); return }
        #expect(found.candidate.url == wistia)
        #expect(found.info == expected)
    }

    @Test func reportsTheMostUsefulFailure() async {
        let outcome = await MediaResolver.resolve(
            MediaResolver.candidates(for: MediaHints(pageURL: page, embeds: [wistia]), headers: base)) { candidate in
                if candidate.url == page { throw MediaQueryError.unsupportedURL }
                throw MediaQueryError.failed("HTTP Error 403: Forbidden")
            }
        #expect(outcome == .failure(.failed("HTTP Error 403: Forbidden")),
                "a concrete yt-dlp error beats 'unsupported URL'")
    }

    @Test func prefersThePageTitleOverAFilePathTitle() {
        // Wistia titles uploads by their storage path.
        #expect(MediaResolver.displayTitle(ytDLPTitle: "file-uploads/sites/2148805051/video/edb156d_Ka_2_7.mp4",
                                           pageTitle: "Karizma İnşa Etmek | Ders 2") == "Karizma İnşa Etmek | Ders 2")
        #expect(MediaResolver.displayTitle(ytDLPTitle: "Ka_2_7.mp4", pageTitle: "Ders 2") == "Ders 2")
        #expect(MediaResolver.displayTitle(ytDLPTitle: "Never Gonna Give You Up", pageTitle: "YouTube") == "Never Gonna Give You Up")
        #expect(MediaResolver.displayTitle(ytDLPTitle: "a/b.mp4", pageTitle: "  ") == "a/b.mp4")
    }

    @Test func noCandidatesFailsAsUnsupported() async {
        let outcome = await MediaResolver.resolve([]) { _ in throw MediaQueryError.timedOut }
        #expect(outcome == .failure(.unsupportedURL))
    }
}

actor TriedURLs {
    var urls: [URL] = []
    func add(_ url: URL) { urls.append(url) }
}
