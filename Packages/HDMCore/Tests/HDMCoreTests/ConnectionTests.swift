import Foundation
import Testing
@testable import HDMCore
import HDMTestSupport

@Suite struct ConnectionTests {
    @Test func streamsRangeIntoSegmentTable() async throws {
        let body = TestData.random(count: 256 * 1024)
        let server = try TestHTTPServer(.init(body: body))
        try await server.start()
        defer { server.stop() }
        let url = tempDirectory().appendingPathComponent("c.hdmpart")
        let table = SegmentTable(segments: [Segment(start: 0, end: 131_072)], planner: SegmentPlanner(minSegment: 65_536),
                                 file: try PartFile(url: url))
        var request = URLRequest(url: server.url)
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")

        let result: ConnectionResult = await withCheckedContinuation { continuation in
            let connection = Connection(request: request, timeout: 10, limiters: [], handlers: ConnectionHandlers(
                onResponse: { $0.statusCode == 206 },
                onData: { data in (try? table.write(data, segment: 0)) == .segmentDone ? .done : .more },
                onComplete: { continuation.resume(returning: $0) }))
            connection.start()
        }
        #expect(result == .segmentDone)
        table.closeFile()
        #expect(try Data(contentsOf: url) == body.prefix(131_072))
    }

    @Test func rejectedResponseReportsRejected() async throws {
        let server = try TestHTTPServer(.init(body: Data(count: 10)))
        try await server.start()
        defer { server.stop() }
        let result: ConnectionResult = await withCheckedContinuation { continuation in
            let connection = Connection(request: URLRequest(url: server.url), timeout: 10, limiters: [], handlers: ConnectionHandlers(
                onResponse: { _ in false }, onData: { _ in .more }, onComplete: { continuation.resume(returning: $0) }))
            connection.start()
        }
        #expect(result == .rejected)
    }

    @Test func probeReadsHeadersWithoutDownloadingBody() async throws {
        var config = TestHTTPServer.Config(body: TestData.random(count: 500_000))
        config.contentDisposition = #"attachment; filename="probe.bin""#
        let server = try TestHTTPServer(config)
        try await server.start()
        defer { server.stop() }
        let result = try await HTTPProbe.probe(url: server.url)
        #expect(result.totalBytes == 500_000 && result.resumable && result.etag == "\"v1\"")
        #expect(result.contentDisposition == #"attachment; filename="probe.bin""#)
        #expect(server.requests.first?.headers["range"] == "bytes=0-")
        #expect(server.requests.first?.headers["accept-encoding"] == "identity")
    }

    @Test func probeWithoutRangeSupport() async throws {
        var config = TestHTTPServer.Config(body: Data(count: 1234))
        config.supportsRange = false
        let server = try TestHTTPServer(config)
        try await server.start()
        defer { server.stop() }
        let result = try await HTTPProbe.probe(url: server.url)
        #expect(result.totalBytes == 1234 && !result.resumable)
    }

    @Test func probeTreatsUnsatisfiableEmptyFileAsEmpty() async throws {   // nginx/S3: 416 bytes */0
        let server = try TestHTTPServer(.init(body: Data()))
        try await server.start()
        defer { server.stop() }
        let result = try await HTTPProbe.probe(url: server.url)
        #expect(result.isEmptyFile && result.totalBytes == 0 && !result.resumable)
    }

    @Test func probeThrowsOnHTTPError() async throws {
        var config = TestHTTPServer.Config(body: Data(count: 1))
        config.statusSequence = [404]
        let server = try TestHTTPServer(config)
        try await server.start()
        defer { server.stop() }
        await #expect(throws: ProbeError.http(404)) { try await HTTPProbe.probe(url: server.url) }
    }
}
