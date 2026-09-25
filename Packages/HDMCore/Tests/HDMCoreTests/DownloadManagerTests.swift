import CoreServices
import Foundation
import Testing
@testable import HDMCore
import HDMTestSupport

@MainActor @Suite(.serialized) struct DownloadManagerTests {
    func makeManager(dir: URL, suite: String, configure: (inout AppSettings) -> Void = { _ in }) -> DownloadManager {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        var s = settings.settings
        s.baseFolder = dir
        configure(&s)
        settings.settings = s
        return DownloadManager(store: DownloadStore(fileURL: dir.appendingPathComponent("downloads.json")),
                               settings: settings, minSegment: 64 * 1024, backoff: fastBackoff)
    }

    func serve(_ body: Data, _ configure: (inout TestHTTPServer.Config) -> Void = { _ in }) async throws -> TestHTTPServer {
        var config = TestHTTPServer.Config(body: body)
        configure(&config)
        let server = try TestHTTPServer(config)
        try await server.start()
        return server
    }

    @Test func completesMovesAndQuarantinesFile() async throws {
        let body = TestData.random(count: 1024 * 1024)
        let server = try await serve(body)
        defer { server.stop() }
        let dir = tempDirectory()
        let manager = makeManager(dir: dir, suite: UUID().uuidString)
        let id = manager.add(NewDownload(url: server.url, fileName: "test.bin", directory: dir, category: .general))
        try await waitUntil { manager.item(id)?.status == .completed }
        let item = try #require(manager.item(id))
        #expect(try TestData.sha256(fileAt: item.fileURL) == TestData.sha256(body))
        #expect(!FileManager.default.fileExists(atPath: item.partURL.path))
        let quarantine = try item.fileURL.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine?[kLSQuarantineAgentNameKey as String] as? String == "Hiz Download Manager")
    }

    @Test func respectsConcurrencyLimit() async throws {
        let server = try await serve(TestData.random(count: 1024 * 1024)) { $0.bytesPerSecondPerConnection = 32 * 1024 }
        defer { server.stop() }
        let dir = tempDirectory()
        let manager = makeManager(dir: dir, suite: UUID().uuidString) { $0.maxConcurrentDownloads = 1 }
        let a = manager.add(NewDownload(url: server.url, fileName: "a.bin", directory: dir, category: .general))
        let b = manager.add(NewDownload(url: server.url, fileName: "b.bin", directory: dir, category: .general))
        try await waitUntil { manager.item(a)?.status == .downloading }
        #expect(manager.item(b)?.status == .queued)
        #expect(manager.activeCount == 1)
        await manager.pauseAll()
    }

    @Test func laterItemsWaitForQueueStart() async throws {
        let server = try await serve(TestData.random(count: 100_000))
        defer { server.stop() }
        let dir = tempDirectory()
        let manager = makeManager(dir: dir, suite: UUID().uuidString)
        let id = manager.add(NewDownload(url: server.url, fileName: "later.bin", directory: dir, category: .general, autoStart: false))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(manager.item(id)?.status == .queued)
        manager.startQueue()
        try await waitUntil { manager.item(id)?.status == .completed }
    }

    @Test func resumesAfterRelaunch() async throws {   // Review Focus 4
        let body = TestData.random(count: 4 * 1024 * 1024)
        let server = try await serve(body) { $0.bytesPerSecondPerConnection = 128 * 1024 }
        defer { server.stop() }
        let dir = tempDirectory()
        let suite = UUID().uuidString
        let first = makeManager(dir: dir, suite: suite)
        let id = first.add(NewDownload(url: server.url, fileName: "big.bin", directory: dir, category: .general))
        try await waitUntil { (first.item(id)?.receivedBytes ?? 0) > 100_000 }
        await first.prepareForTermination()
        #expect(first.item(id)?.status == .paused)

        let second = makeManager(dir: dir, suite: suite)
        let restored = try #require(second.item(id))
        #expect(restored.status == .paused)
        #expect(restored.receivedBytes > 0 && !restored.segments.isEmpty)
        server.update { $0.bytesPerSecondPerConnection = nil }
        second.resume([id])
        try await waitUntil { second.item(id)?.status == .completed }
        #expect(try TestData.sha256(fileAt: try #require(second.item(id)).fileURL) == TestData.sha256(body))
    }

    @Test func runningItemsBecomePausedOnLaunch() throws {
        let dir = tempDirectory()
        var item = DownloadItem(url: URL(string: "https://e.com/x")!, fileName: "x", saveDirectory: dir, category: .general)
        item.status = .downloading
        try DownloadStore(fileURL: dir.appendingPathComponent("downloads.json")).save([item])
        let manager = makeManager(dir: dir, suite: UUID().uuidString)
        #expect(manager.item(item.id)?.status == .paused)
    }

    @Test func renamesOnNameCollision() async throws {   // Review Focus 3
        let body = TestData.random(count: 50_000)
        let server = try await serve(body)
        defer { server.stop() }
        let dir = tempDirectory()
        let existing = dir.appendingPathComponent("rapor ü.bin")
        try Data("old".utf8).write(to: existing)
        let manager = makeManager(dir: dir, suite: UUID().uuidString)
        let id = manager.add(NewDownload(url: server.url, fileName: "rapor ü.bin", directory: dir, category: .general))
        try await waitUntil { manager.item(id)?.status == .completed }
        let item = try #require(manager.item(id))
        #expect(item.fileName == "rapor ü (2).bin")
        #expect(try Data(contentsOf: existing) == Data("old".utf8))
        #expect(try TestData.sha256(fileAt: item.fileURL) == TestData.sha256(body))
    }

    @Test func removeDeletesPartialFile() async throws {
        let server = try await serve(TestData.random(count: 1024 * 1024)) { $0.bytesPerSecondPerConnection = 32 * 1024 }
        defer { server.stop() }
        let dir = tempDirectory()
        let manager = makeManager(dir: dir, suite: UUID().uuidString)
        let id = manager.add(NewDownload(url: server.url, fileName: "p.bin", directory: dir, category: .general))
        try await waitUntil { manager.item(id)?.status == .downloading }
        let part = try #require(manager.item(id)).partURL
        manager.remove([id], deleteFiles: false)
        #expect(manager.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: part.path))
    }

    @Test func refreshedLinkContinuesDownload() async throws {
        let body = TestData.random(count: 200_000)
        let server = try await serve(body) { $0.statusSequence = [403] }
        defer { server.stop() }
        let dir = tempDirectory()
        let manager = makeManager(dir: dir, suite: UUID().uuidString)
        let id = manager.add(NewDownload(url: server.url, fileName: "r.bin", directory: dir, category: .general))
        try await waitUntil { manager.item(id)?.status == .needsRefresh }
        #expect(manager.refreshCandidate(fileName: "r.bin", totalBytes: nil)?.id == id)
        #expect(manager.refreshCandidate(fileName: "other.bin", totalBytes: nil) == nil)
        manager.applyRefreshedLink(id, url: server.url, headers: [:], pageURL: nil, referrer: nil)
        try await waitUntil { manager.item(id)?.status == .completed }
    }
}

/// Regression tests from the Phase 1 whole-branch review.
@MainActor @Suite(.serialized) struct DownloadManagerReviewTests {
    func serve(_ body: Data, _ configure: (inout TestHTTPServer.Config) -> Void = { _ in }) async throws -> TestHTTPServer {
        var config = TestHTTPServer.Config(body: body)
        configure(&config)
        let server = try TestHTTPServer(config)
        try await server.start()
        return server
    }

    func makeManager(dir: URL, configure: (inout AppSettings) -> Void = { _ in }) -> DownloadManager {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        var s = settings.settings
        s.baseFolder = dir
        configure(&s)
        settings.settings = s
        return DownloadManager(store: DownloadStore(fileURL: dir.appendingPathComponent("downloads.json")),
                               settings: settings, minSegment: 64 * 1024, backoff: fastBackoff)
    }

    func isTerminal(_ status: DownloadStatus?) -> Bool {
        switch status { case .completed?, .failed?: true; default: false }
    }

    @Test func sameNameItemsNeverShareAPartFile() async throws {
        let bodyA = TestData.random(count: 2 * 1024 * 1024, seed: 11)
        let bodyB = TestData.random(count: 2 * 1024 * 1024, seed: 22)
        let a = try await serve(bodyA) { $0.bytesPerSecondPerConnection = 512 * 1024 }
        let b = try await serve(bodyB) { $0.bytesPerSecondPerConnection = 512 * 1024 }
        defer { a.stop(); b.stop() }
        let dir = tempDirectory()
        let manager = makeManager(dir: dir)
        let idA = manager.add(NewDownload(url: a.url, fileName: "setup.zip", directory: dir, category: .general, autoStart: false))
        let idB = manager.add(NewDownload(url: b.url, fileName: "setup.zip", directory: dir, category: .general, autoStart: false))
        #expect(manager.item(idA)?.fileName != manager.item(idB)?.fileName)
        manager.startQueue()
        try await waitUntil(timeout: 20) { isTerminal(manager.item(idA)?.status) && isTerminal(manager.item(idB)?.status) }
        let itemA = try #require(manager.item(idA)), itemB = try #require(manager.item(idB))
        #expect(itemA.status == .completed && itemB.status == .completed)
        #expect(try TestData.sha256(fileAt: itemA.fileURL) == TestData.sha256(bodyA))
        #expect(try TestData.sha256(fileAt: itemB.fileURL) == TestData.sha256(bodyB))
    }

    @Test func queueStopsOnceItsItemsHaveStarted() async throws {
        let server = try await serve(TestData.random(count: 50_000))
        defer { server.stop() }
        let dir = tempDirectory()
        let manager = makeManager(dir: dir)
        let first = manager.add(NewDownload(url: server.url, fileName: "one.bin", directory: dir, category: .general, autoStart: false))
        manager.startQueue()
        try await waitUntil { manager.item(first)?.status == .completed }
        #expect(!manager.queueRunning)
        let later = manager.add(NewDownload(url: server.url, fileName: "two.bin", directory: dir, category: .general, autoStart: false))
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(manager.item(later)?.status == .queued)
    }

    @Test func overwriteNeverReplacesADirectory() async throws {
        let body = TestData.random(count: 20_000)
        let server = try await serve(body)
        defer { server.stop() }
        let dir = tempDirectory()
        let folder = dir.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: folder.appendingPathComponent("important.txt"))
        let manager = makeManager(dir: dir) { $0.conflictPolicy = .overwrite }
        let id = manager.add(NewDownload(url: server.url, fileName: "Documents", directory: dir, category: .general))
        try await waitUntil { isTerminal(manager.item(id)?.status) }
        let item = try #require(manager.item(id))
        #expect(item.status == .completed)
        #expect(item.fileName == "Documents (2)")
        #expect(try Data(contentsOf: folder.appendingPathComponent("important.txt")) == Data("keep".utf8))
    }

    @Test func pauseRacingRedownloadDoesNotClobberTheNewRun() async throws {
        let server = try await serve(TestData.random(count: 2 * 1024 * 1024)) { $0.bytesPerSecondPerConnection = 128 * 1024 }
        defer { server.stop() }
        let dir = tempDirectory()
        let manager = makeManager(dir: dir)
        let id = manager.add(NewDownload(url: server.url, fileName: "race.bin", directory: dir, category: .general))
        try await waitUntil { manager.item(id)?.status == .downloading }
        let pausing = Task { await manager.pause([id]) }
        await Task.yield()                      // let pause() reach its await on the old run
        manager.redownload(id)                  // user clicks Redownload meanwhile
        await pausing.value
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(manager.item(id)?.status.isRunning == true, "status: \(String(describing: manager.item(id)?.status))")
        await manager.pauseAll()
    }

    @Test func credentialsCanBeAddedAfterAuthFailure() async throws {   // spec §5.5 401 → ask for user/password
        let body = TestData.random(count: 30_000)
        let server = try await serve(body) { $0.statusSequence = [401] }
        defer { server.stop() }
        let dir = tempDirectory()
        let manager = makeManager(dir: dir)
        let id = manager.add(NewDownload(url: server.url, fileName: "auth.bin", directory: dir, category: .general))
        try await waitUntil { manager.item(id)?.status == .failed(.authRequired) }
        manager.setHeader(id, name: "Authorization", value: "Basic dTpw")
        manager.resume([id])
        try await waitUntil { manager.item(id)?.status == .completed }
        #expect(server.requests.last?.headers["authorization"] == "Basic dTpw")
    }
}
