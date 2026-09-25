import Foundation
import Testing
@testable import HDMCore

@Suite struct FilenameResolverTests {
    @Test func parsesContentDisposition() {
        #expect(FilenameResolver.parseContentDisposition(#"attachment; filename="report.pdf""#) == "report.pdf")
        #expect(FilenameResolver.parseContentDisposition("attachment; filename*=UTF-8''%C3%BCcret.txt") == "ücret.txt")
        #expect(FilenameResolver.parseContentDisposition(#"attachment; filename="plain.txt"; filename*=UTF-8''fancy%20name.txt"#) == "fancy name.txt")
        #expect(FilenameResolver.parseContentDisposition(#"attachment; filename="a;b.zip""#) == "a;b.zip")
        #expect(FilenameResolver.parseContentDisposition("inline") == nil)
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
