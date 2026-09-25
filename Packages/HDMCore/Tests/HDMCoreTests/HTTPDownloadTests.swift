import Foundation
import Testing
@testable import HDMCore
import HDMTestSupport

extension DownloadEvent {
    var isFinished: Bool { if case .finished = self { true } else { false } }
    var failure: FailureReason? { if case .failed(let reason) = self { reason } else { nil } }
    var refreshStatus: Int? { if case .needsRefresh(let code) = self { code } else { nil } }
    var probe: ProbeResult? { if case .probed(let p) = self { p } else { nil } }
}

func collect(_ download: HTTPDownload) async -> [DownloadEvent] {
    var events: [DownloadEvent] = []
    for await event in download.events { events.append(event) }
    return events
}

@Suite(.serialized) struct HTTPDownloadTests {
    let kib = 1024

    func serve(_ body: Data, _ configure: (inout TestHTTPServer.Config) -> Void = { _ in }) async throws -> TestHTTPServer {
        var config = TestHTTPServer.Config(body: body)
        configure(&config)
        let server = try TestHTTPServer(config)
        try await server.start()
        return server
    }

    func download(_ server: TestHTTPServer, part: URL, resume: ResumeState? = nil, connections: Int = 8,
                  retries: Int = 10, limiters: [SpeedLimiter] = []) -> HTTPDownload {
        HTTPDownload(request: DownloadRequest(url: server.url, partURL: part, resume: resume, maxConnections: connections,
                                              retryLimit: retries, timeout: 10, minSegment: 64 * 1024),
                     limiters: limiters, backoff: fastBackoff)
    }

    @Test func downloadsWithMultipleConnections() async throws {
        let body = TestData.random(count: 3 * 1024 * 1024)
        let server = try await serve(body) { $0.bytesPerSecondPerConnection = 2 * 1024 * 1024 }
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let dl = download(server, part: part)
        await dl.start()
        let events = await collect(dl)
        #expect(events.last?.isFinished == true)
        #expect(events.compactMap(\.probe).first?.resumable == true)
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
        #expect(server.maxObservedConcurrency >= 2)
    }

    @Test func parallelConnectionsAreFaster() async throws {
        let body = TestData.random(count: 2 * 1024 * 1024)
        let server = try await serve(body) { $0.bytesPerSecondPerConnection = 256 * 1024 }
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let dl = download(server, part: part)
        let started = Date()
        await dl.start()
        let events = await collect(dl)
        let elapsed = Date().timeIntervalSince(started)
        #expect(events.last?.isFinished == true)
        #expect(elapsed < 2.5, "one connection would need 8 s, took \(elapsed)")
        #expect(server.maxObservedConcurrency >= 6)
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
    }

    @Test func fallsBackToOneConnectionWithoutRanges() async throws {
        let body = TestData.random(count: 700 * 1024)
        let server = try await serve(body) { $0.supportsRange = false }
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let dl = download(server, part: part)
        await dl.start()
        let events = await collect(dl)
        #expect(events.last?.isFinished == true)
        #expect(events.compactMap(\.probe).first?.resumable == false)
        #expect(server.requests.count == 1)
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
    }

    @Test func downloadsUnknownLength() async throws {
        let body = TestData.random(count: 300 * 1024)
        let server = try await serve(body) { $0.supportsRange = false; $0.sendContentLength = false }
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let dl = download(server, part: part)
        await dl.start()
        let events = await collect(dl)
        guard case .finished(let total) = events.last else { Issue.record("not finished: \(events.last as Any)"); return }
        #expect(total == Int64(body.count))
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
    }

    @Test(arguments: [0, 10])
    func downloadsTinyFiles(size: Int) async throws {   // Review Focus 1
        let body = TestData.random(count: size)
        let server = try await serve(body)
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let dl = download(server, part: part)
        await dl.start()
        let events = await collect(dl)
        #expect(events.last?.isFinished == true)
        #expect(try Data(contentsOf: part) == body)
    }

    @Test func respectsSpeedLimit() async throws {
        // 4 MB at 2 MB/s. Throttling works by pausing reads, so each connection's socket buffer can
        // slip through; the file must be large next to those buffers for the limit to be measurable.
        // Paced like a real network (small chunks); unlimited, this takes about 0.15 s.
        let body = TestData.random(count: 4 * 1024 * 1024)
        let server = try await serve(body) { $0.bytesPerSecondPerConnection = 4 * 1024 * 1024 }
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let dl = download(server, part: part, limiters: [SpeedLimiter(bytesPerSecond: 2 * 1024 * 1024)])
        let started = Date()
        await dl.start()
        let events = await collect(dl)
        let elapsed = Date().timeIntervalSince(started)
        #expect(events.last?.isFinished == true)
        #expect(elapsed > 0.8, "limit ignored, took \(elapsed) s")
        #expect(elapsed < 10)
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
    }

    /// Starts a throttled download and pauses it once some data has arrived.
    func startAndPause(_ server: TestHTTPServer, part: URL) async -> (segments: [Segment], probe: ProbeResult?) {
        let first = download(server, part: part, connections: 4)
        await first.start()
        var probe: ProbeResult?
        for await event in first.events {
            if case .probed(let p) = event { probe = p }
            if case .progress(let snapshot) = event, snapshot.receivedBytes > 256 * 1024 { break }
        }
        return (await first.pause(), probe)
    }

    @Test func resumesFromSavedSegments() async throws {
        let body = TestData.random(count: 2 * 1024 * 1024)
        let server = try await serve(body) { $0.bytesPerSecondPerConnection = 256 * 1024 }
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let (segments, probe) = await startAndPause(server, part: part)
        let received = segments.reduce(0) { $0 + $1.received }
        #expect(received > 0 && received < Int64(body.count))

        server.update { $0.bytesPerSecondPerConnection = nil }
        let before = server.requests.count
        let resume = ResumeState(segments: segments, totalBytes: Int64(body.count), etag: probe?.etag, lastModified: probe?.lastModified)
        let second = download(server, part: part, resume: resume, connections: 4)
        await second.start()
        let events = await collect(second)
        #expect(events.last?.isFinished == true)
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
        #expect(server.requests.dropFirst(before).allSatisfy { $0.headers["if-range"] == "\"v1\"" })
    }

    @Test func detectsChangedFileOnResume() async throws {
        let body = TestData.random(count: 2 * 1024 * 1024)
        let server = try await serve(body) { $0.bytesPerSecondPerConnection = 256 * 1024 }
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let (segments, probe) = await startAndPause(server, part: part)
        server.update { $0.etag = "\"v2\""; $0.body = TestData.random(count: 2 * 1024 * 1024, seed: 7); $0.bytesPerSecondPerConnection = nil }
        let resume = ResumeState(segments: segments, totalBytes: Int64(body.count), etag: probe?.etag, lastModified: probe?.lastModified)
        let second = download(server, part: part, resume: resume, connections: 4)
        await second.start()
        let events = await collect(second)
        #expect(events.last?.failure == .serverFileChanged)
    }

    @Test func restartsWhenPartFileIsMissing() async throws {   // Review Focus 2
        let body = TestData.random(count: 512 * 1024)
        let server = try await serve(body)
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("gone.hdmpart")
        let resume = ResumeState(segments: [Segment(start: 0, end: 262_144, received: 262_144), Segment(start: 262_144, end: 524_288)],
                                 totalBytes: 524_288, etag: "\"v1\"", lastModified: nil)
        let dl = download(server, part: part, resume: resume)
        await dl.start()
        let events = await collect(dl)
        #expect(events.last?.isFinished == true)
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
    }

    @Test func retriesDroppedConnection() async throws {
        let body = TestData.random(count: 1024 * 1024)
        let server = try await serve(body) { $0.dropOnceAfterBytes = 100_000 }
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let dl = download(server, part: part)
        await dl.start()
        let events = await collect(dl)
        #expect(events.last?.isFinished == true)
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
    }

    @Test func reportsNeedsRefreshOn403() async throws {
        let server = try await serve(TestData.random(count: 1000)) { $0.statusSequence = [403] }
        defer { server.stop() }
        let dl = download(server, part: tempDirectory().appendingPathComponent("f.hdmpart"))
        await dl.start()
        let events = await collect(dl)
        #expect(events.last?.refreshStatus == 403)
    }

    @Test func completesWhenServerLimitsConnections() async throws {   // Review Focus 5
        let body = TestData.random(count: 1024 * 1024)
        let server = try await serve(body) { $0.maxConcurrentConnections = 2; $0.bytesPerSecondPerConnection = 1024 * 1024 }
        defer { server.stop() }
        let part = tempDirectory().appendingPathComponent("f.hdmpart")
        let dl = download(server, part: part)
        await dl.start()
        let events = await collect(dl)
        #expect(events.last?.isFinished == true)
        #expect(try TestData.sha256(fileAt: part) == TestData.sha256(body))
    }

    @Test func failsAfterRetryLimit() async throws {
        let server = try await serve(Data(count: 10)) { $0.statusSequence = [500, 500, 500, 500] }
        defer { server.stop() }
        let dl = download(server, part: tempDirectory().appendingPathComponent("f.hdmpart"), retries: 2)
        await dl.start()
        let events = await collect(dl)
        guard case .network = events.last?.failure else { Issue.record("expected network failure, got \(events.last as Any)"); return }
    }
}
