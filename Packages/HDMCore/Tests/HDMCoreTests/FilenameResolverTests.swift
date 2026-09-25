import Foundation
import Testing
@testable import HDMCore
import HDMTestSupport

@Suite struct FilenameResolverTests {
    @Test func parsesContentDisposition() {
        #expect(FilenameResolver.parseContentDisposition(#"attachment; filename="report.pdf""#) == "report.pdf")
        #expect(FilenameResolver.parseContentDisposition("attachment; filename*=UTF-8''%C3%BCcret.txt") == "ücret.txt")
        #expect(FilenameResolver.parseContentDisposition(#"attachment; filename="plain.txt"; filename*=UTF-8''fancy%20name.txt"#) == "fancy name.txt")
        #expect(FilenameResolver.parseContentDisposition(#"attachment; filename="a;b.zip""#) == "a;b.zip")
        #expect(FilenameResolver.parseContentDisposition("inline") == nil)
    }

    @Test func repairsRawUTF8NamesDecodedAsLatin1() {
        // CFNetwork decodes header bytes as Latin-1, so raw UTF-8 "rapor ü.pdf" arrives as "rapor Ã¼.pdf".
        #expect(FilenameResolver.parseContentDisposition("attachment; filename=\"rapor \u{C3}\u{BC}.pdf\"") == "rapor ü.pdf")
        #expect(FilenameResolver.parseContentDisposition("attachment; filename=\"\u{C3}\u{A7}\u{C4}\u{B1}k\u{C4}\u{B1}\u{C5}\u{9F}.zip\"") == "çıkış.zip")
        // Genuine Latin-1 that is not valid UTF-8 stays as it is.
        #expect(FilenameResolver.parseContentDisposition("attachment; filename=\"caf\u{E9}.txt\"") == "café.txt")
    }

    @Test func probeHeaderWithRawUTF8Name() async throws {
        var config = TestHTTPServer.Config(body: Data(count: 10))
        config.contentDisposition = "attachment; filename=\"rapor ü.pdf\""
        let server = try TestHTTPServer(config)
        try await server.start()
        defer { server.stop() }
        let probe = try await HTTPProbe.probe(url: server.url)
        #expect(FilenameResolver.resolve(contentDisposition: probe.contentDisposition, url: server.url) == "rapor ü.pdf")
    }

    @Test func resolvesInPriorityOrder() {
        let url = URL(string: "https://x.com/files/My%20File.zip?token=1")!
        #expect(FilenameResolver.resolve(userProvided: "mine.zip", contentDisposition: #"attachment; filename="cd.zip""#, url: url) == "mine.zip")
        #expect(FilenameResolver.resolve(contentDisposition: #"attachment; filename="cd.zip""#, suggested: "s.zip", url: url) == "cd.zip")
        #expect(FilenameResolver.resolve(suggested: "s.zip", url: url) == "s.zip")
        #expect(FilenameResolver.resolve(url: url) == "My File.zip")
        #expect(FilenameResolver.resolve(url: URL(string: "https://x.com/")!, mimeType: "application/pdf") == "index.pdf")
        #expect(FilenameResolver.resolve(url: URL(string: "https://x.com/get")!, mimeType: "application/octet-stream") == "get")
    }

    @Test func sanitizesDangerousNames() {
        #expect(FilenameResolver.sanitize("../../etc/passwd") == "_.._etc_passwd")
        #expect(FilenameResolver.sanitize("a\u{0}b:c") == "ab_c")
        #expect(FilenameResolver.sanitize("   ") == "download")
        #expect(FilenameResolver.sanitize(".hidden") == "hidden")
        let long = FilenameResolver.sanitize(String(repeating: "a", count: 300) + ".zip")
        #expect(long.utf8.count == 255 && long.hasSuffix(".zip"))
    }

    @Test func makesUniqueNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(FilenameResolver.uniqueName("a.zip", in: dir) == "a.zip")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a.zip").path, contents: Data())
        #expect(FilenameResolver.uniqueName("a.zip", in: dir) == "a (2).zip")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("a (2).zip").path, contents: Data())
        #expect(FilenameResolver.uniqueName("a.zip", in: dir) == "a (3).zip")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("b.zip.hdmpart").path, contents: Data())
        #expect(FilenameResolver.uniqueName("b.zip", in: dir) == "b (2).zip")
        FileManager.default.createFile(atPath: dir.appendingPathComponent("readme").path, contents: Data())
        #expect(FilenameResolver.uniqueName("readme", in: dir) == "readme (2)")
    }
}
