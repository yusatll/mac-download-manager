import Foundation
import Testing
import HDMTestSupport

@Suite struct TestHTTPServerTests {
    func session() -> URLSession { URLSession(configuration: .ephemeral) }

    @Test func servesRangesAndHonoursIfRange() async throws {
        let body = TestData.random(count: 1000)
        let server = try TestHTTPServer(.init(body: body))
        try await server.start()
        defer { server.stop() }

        var request = URLRequest(url: server.url)
        request.setValue("bytes=10-19", forHTTPHeaderField: "Range")
        let (data, response) = try await session().data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 206)
        #expect(http.value(forHTTPHeaderField: "Content-Range") == "bytes 10-19/1000")
        #expect(data == body.subdata(in: 10..<20))

        request.setValue("\"other\"", forHTTPHeaderField: "If-Range")
        let (full, fullResponse) = try await session().data(for: request)
        #expect((fullResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(full == body)
        #expect(server.requests.last?.headers["if-range"] == "\"other\"")
    }

    @Test func forcedStatusesComeFirst() async throws {
        let server = try TestHTTPServer({ var c = TestHTTPServer.Config(body: Data("ok".utf8)); c.statusSequence = [403]; return c }())
        try await server.start()
        defer { server.stop() }
        let (_, first) = try await session().data(from: server.url)
        let (second, _) = try await session().data(from: server.url)
        #expect((first as? HTTPURLResponse)?.statusCode == 403)
        #expect(second == Data("ok".utf8))
    }
}
