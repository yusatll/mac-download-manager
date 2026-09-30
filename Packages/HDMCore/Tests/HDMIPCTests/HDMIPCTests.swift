import Foundation
import Testing
@testable import HDMIPC

@Suite struct HDMIPCProtocolTests {
    @Test func framingRoundTripsLittleEndianLength() throws {
        let message = IPCMessage(type: "ping")
        let frame = try IPCFrame.encode(message)
        #expect(frame.count == 4 + (try JSONEncoder().encode(message)).count)
        let length = try #require(IPCFrame.decodeLength(frame.prefix(4)))
        #expect(Int(length) == frame.count - 4)
        let body = frame.suffix(Int(length))
        let decoded = try IPCFrame.decode(IPCMessage.self, from: Data(body))
        #expect(decoded.id == message.id)
        #expect(decoded.type == "ping")
    }

    @Test func littleEndianLengthDecoding() {
        // 0x01020304 little-endian is bytes 04 03 02 01 → 0x01020304
        #expect(IPCFrame.decodeLength(Data([0x04, 0x03, 0x02, 0x01])) == 0x0102_0304)
        #expect(IPCFrame.decodeLength(Data([0x39, 0x30, 0x00, 0x00])) == 12_345)
        #expect(IPCFrame.decodeLength(Data([0x00])) == nil)
    }

    @Test func downloadMessageDecodesFlatJSON() throws {
        let json = #"{"v":1,"id":"abc","type":"download","url":"https://cdn.e.com/f.zip","filename":"f.zip","size":123,"source":"capture","cookies":"a=b","userAgent":"UA"}"#
        let message = try IPCFrame.decode(IPCMessage.self, from: Data(json.utf8))
        guard case .download(let download) = message.payload else {
            Issue.record("expected download payload")
            return
        }
        #expect(download.url.absoluteString == "https://cdn.e.com/f.zip")
        #expect(download.filename == "f.zip")
        #expect(download.size == 123)
        #expect(download.source == .capture)
        // Re-encoding keeps body fields flat next to the envelope.
        let encoded = String(data: try JSONEncoder().encode(message), encoding: .utf8) ?? ""
        #expect(encoded.contains("\"type\":\"download\""))
        #expect(encoded.contains("\"filename\":\"f.zip\""))
    }

    @Test func rejectsNonHTTPURLs() {
        let json = #"{"v":1,"id":"x","type":"download","url":"file:///etc/passwd"}"#
        #expect(throws: IPCError.self) {
            _ = try IPCFrame.decode(IPCMessage.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsUnknownTypeAndVersion() throws {
        #expect(throws: IPCError.self) {
            _ = try IPCFrame.decode(IPCMessage.self, from: Data(#"{"v":1,"id":"x","type":"nope"}"#.utf8))
        }
        #expect(throws: IPCError.self) {
            _ = try IPCFrame.decode(IPCMessage.self, from: Data(#"{"v":7,"id":"x","type":"ping"}"#.utf8))
        }
    }

    /// Strips the length prefix so the JSON body can be decoded.
    private func body(of frame: Data) throws -> Data {
        let length = try #require(IPCFrame.decodeLength(frame.prefix(4)))
        return frame.suffix(Int(length))
    }

    @Test func responseRoundTrip() throws {
        let response = IPCResponse(
            id: "q1", hello: HelloOut(appVersion: "0.2", captureEnabled: true, fileTypes: ["zip"],
                                      exceptions: ["*.apple.com"], minimumSizeBytes: 0, panelEnabled: true))
        let back = try IPCFrame.decode(IPCResponse.self, from: body(of: try IPCFrame.encode(response)))
        #expect(back.id == "q1")
        #expect(back.ok)
        #expect(back.hello?.fileTypes == ["zip"])
        #expect(back.hello?.exceptions == ["*.apple.com"])

        let failure = IPCResponse(id: "q2", ok: false, error: "app_unavailable")
        let failureBack = try IPCFrame.decode(IPCResponse.self, from: body(of: try IPCFrame.encode(failure)))
        #expect(!failureBack.ok && failureBack.error == "app_unavailable")
    }

    @Test func mediaQueryRoundTrip() throws {
        let json = #"{"v":1,"id":"m1","type":"mediaQuery","pageUrl":"https://youtube.com/watch?v=x","title":"T","streams":[{"url":"https://e.com/a.m3u8","kind":"hls"}]}"#
        let message = try IPCFrame.decode(IPCMessage.self, from: Data(json.utf8))
        guard case .mediaQuery(let query) = message.payload else {
            Issue.record("expected mediaQuery payload")
            return
        }
        #expect(query.title == "T")
        #expect(query.streams.first?.kind == .hls)

        let out = IPCResponse(id: "m1", mediaQuery: MediaQueryOut(
            queryId: "q", title: "T",
            formats: [MediaQueryOut.Format(id: "1080p", label: "1080p", ext: "MP4", approxSize: 5, note: nil)]))
        let outBack = try IPCFrame.decode(IPCResponse.self, from: body(of: try IPCFrame.encode(out)))
        #expect(outBack.mediaQuery?.formats.first?.id == "1080p")
    }

    @Test func mediaQueryCarriesEmbedsAndFrameURLs() throws {
        let json = #"""
        {"v":1,"id":"m2","type":"mediaQuery","pageUrl":"https://site.com/posts/2",
         "embeds":["https://fast.wistia.net/embed/iframe/m3m3xookbb","javascript:alert(1)","file:///etc/passwd"],
         "streams":[{"url":"https://w.com/d.bin","kind":"file","mime":"video/mp4","frameUrl":"https://fast.wistia.net/embed/iframe/x"},
                    {"url":"file:///etc/passwd","kind":"file"}]}
        """#
        let message = try IPCFrame.decode(IPCMessage.self, from: Data(json.utf8))
        guard case .mediaQuery(let query) = message.payload else {
            Issue.record("expected mediaQuery payload")
            return
        }
        #expect(query.embeds == [URL(string: "https://fast.wistia.net/embed/iframe/m3m3xookbb")!], "only http(s) embeds survive")
        #expect(query.streams.map(\.url) == [URL(string: "https://w.com/d.bin")!], "only http(s) streams survive")
        #expect(query.streams.first?.frameUrl == URL(string: "https://fast.wistia.net/embed/iframe/x"))
    }

    @Test func mediaDownloadIgnoresClientSidePaths() throws {
        // The extension may never pick the destination (spec §10).
        let json = #"{"v":1,"id":"d1","type":"mediaDownload","queryId":"q","formatId":"720p","saveTo":"/etc"}"#
        let message = try IPCFrame.decode(IPCMessage.self, from: Data(json.utf8))
        guard case .mediaDownload(let download) = message.payload else {
            Issue.record("expected mediaDownload payload")
            return
        }
        #expect(download.queryId == "q")
        #expect(download.formatId == "720p")
        #expect(download.saveTo == nil)
    }
}

@Suite(.serialized) struct IPCServerTests {
    private func tempSocket() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdm-ipc-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.sock")
    }

    @Test func serverAnswersRequestOverSocket() async throws {
        let socket = tempSocket()
        let server = IPCServer(socketURL: socket) { message in
            IPCResponse(id: message.id, hello: HelloOut(appVersion: "test", captureEnabled: true,
                                                        fileTypes: [], exceptions: [],
                                                        minimumSizeBytes: 0, panelEnabled: true))
        }
        try server.start()
        defer { server.stop() }

        let message = IPCMessage(type: "hello", payload: .hello(HelloIn(browser: "chrome", extensionVersion: "1.0")))
        let reply = try await IPCClient.request(message, timeout: 5, socketURL: socket)
        #expect(reply.ok)
        #expect(reply.hello?.appVersion == "test")
        #expect(reply.id == message.id)
    }

    @Test func serverSurvivesMalformedInput() async throws {
        let socket = tempSocket()
        let server = IPCServer(socketURL: socket) { message in IPCResponse(id: message.id) }
        try server.start()
        defer { server.stop() }

        // A length header beyond the cap: the server must reply with an error frame and keep serving.
        let connection = try #require(Connection(socketURL: socket))
        defer { connection.close() }
        try connection.write(Data([0xff, 0xff, 0xff, 0x7f]) + Data("{}".utf8))
        let header = try connection.read(4)
        let length = try #require(IPCFrame.decodeLength(header))
        let body = try connection.read(Int(length))
        let errorReply = try IPCFrame.decode(IPCResponse.self, from: body)
        #expect(!errorReply.ok)
        #expect(errorReply.error?.contains("tooLarge") == true || errorReply.error == "bad_request")

        let good = try await IPCClient.request(IPCMessage(type: "ping"), timeout: 5, socketURL: socket)
        #expect(good.ok)
    }

    @Test func concurrentRequestsEachGetTheirReply() async throws {
        let socket = tempSocket()
        let server = IPCServer(socketURL: socket) { message in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return IPCResponse(id: message.id)
        }
        try server.start()
        defer { server.stop() }

        async let a = IPCClient.request(IPCMessage(id: "a", type: "ping"), timeout: 5, socketURL: socket)
        async let b = IPCClient.request(IPCMessage(id: "b", type: "ping"), timeout: 5, socketURL: socket)
        let (first, second) = try await (a, b)
        #expect(first.id == "a" && second.id == "b")
    }

    @Test func clientTimesOutWhenAppMissing() async {
        let socket = tempSocket()
        await #expect(throws: IPCError.self) {
            _ = try await IPCClient.request(IPCMessage(type: "ping"), timeout: 0.5, socketURL: socket)
        }
    }
}
