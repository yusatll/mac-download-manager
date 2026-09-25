import Foundation
import Testing
@testable import HDMCore

@Suite struct ModelTests {
    @Test func segmentMath() {
        let s = Segment(start: 100, end: 200, received: 30)
        #expect(s.cursor == 130)
        #expect(s.remaining == 70)
        #expect(!s.isComplete)
        #expect(Segment(start: 0, end: 10, received: 10).isComplete)
        let open = Segment(start: 0, end: .max, received: 5)
        #expect(open.isOpenEnded && !open.isComplete && open.remaining == .max)
    }

    @Test func categoriesResolveByExtension() {
        let r = CategoryResolver()
        #expect(r.category(forFileName: "a.ZIP") == .compressed)
        #expect(r.category(forFileName: "setup.dmg") == .programs)
        #expect(r.category(forFileName: "film.mkv") == .video)
        #expect(r.category(forFileName: "notes.pdf") == .documents)
        #expect(r.category(forFileName: "song.flac") == .music)
        #expect(r.category(forFileName: "README") == .general)
        #expect(r.category(forFileName: "x.unknown") == .general)
    }

    @Test func settingsDecodeMissingKeysAsDefaults() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(s == AppSettings())
        #expect(s.maxConnections == 8 && s.maxConcurrentDownloads == 4 && s.retryCount == 10)
        let partial = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"maxConnections":16}"#.utf8))
        #expect(partial.maxConnections == 16 && partial.preventSleep)
    }

    @Test func settingsRoundTripWithCategoryFolders() throws {
        var s = AppSettings()
        s.categoryFolders[.video] = URL(fileURLWithPath: "/tmp/v")
        s.conflictPolicy = .ask
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.folder(for: .video).path == "/tmp/v")
        #expect(back.folder(for: .music).lastPathComponent == "Music")
        #expect(back.folder(for: .music).deletingLastPathComponent().lastPathComponent == "HDM")
    }

    @Test func captureExtensionsAreCaseInsensitive() {
        let s = AppSettings()
        #expect(s.shouldCapture(fileName: "Big.ISO"))
        #expect(!s.shouldCapture(fileName: "page.html"))
        #expect(!s.shouldCapture(fileName: "noext"))
    }

    @Test func itemRoundTripsAndDerivesPaths() throws {
        var item = DownloadItem(url: URL(string: "https://e.com/a.zip")!, fileName: "a.zip",
                                saveDirectory: URL(fileURLWithPath: "/tmp/d"), category: .compressed)
        item.status = .failed(.network("offline"))
        item.segments = [Segment(start: 0, end: 10, received: 4)]
        item.totalBytes = 10
        item.receivedBytes = 4
        let back = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(item))
        #expect(back == item)
        #expect(item.partURL.path == "/tmp/d/a.zip.hdmpart")
        #expect(item.fileURL.path == "/tmp/d/a.zip")
        #expect(item.fractionCompleted == 0.4)
        #expect(item.status.canResume && !item.status.isRunning)
        item.resetTransfer()
        #expect(item.segments.isEmpty && item.receivedBytes == 0 && item.totalBytes == nil)
    }
}
