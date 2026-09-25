import Foundation
import Network
import os

public struct RecordedRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
}

/// Minimal HTTP/1.1 server on 127.0.0.1 for engine tests. Every response closes its connection,
/// so each client request is its own TCP connection, just like HDM's segment connections.
public final class TestHTTPServer: @unchecked Sendable {
    public struct Config: Sendable {
        public var body: Data
        public var supportsRange = true
        public var etag: String? = "\"v1\""
        public var lastModified: String? = "Wed, 21 Oct 2015 07:28:00 GMT"
        public var contentDisposition: String?
        public var contentType = "application/octet-stream"
        public var sendContentLength = true
        public var bytesPerSecondPerConnection: Int?
        /// Requests beyond this many in flight get 429.
        public var maxConcurrentConnections: Int?
        /// The first body response is cut after this many bytes.
        public var dropOnceAfterBytes: Int?
        /// Statuses returned (with a tiny body) before normal responses resume.
        public var statusSequence: [Int] = []
        /// Every body response is cut after this many bytes.
        public var dropEveryAfterBytes: Int?
        /// Connections beyond this many in flight are closed without any response (TCP-level refusal).
        public var refuseBeyond: Int?

        public init(body: Data) { self.body = body }
    }

    private let lock = NSLock()
    private var config: Config
    private var active = 0
    private var observedMax = 0
    private var recorded: [RecordedRequest] = []
    private var didDrop = false
    private let listener: NWListener
    private let queue = DispatchQueue(label: "hdm.testserver")

    public init(_ config: Config) throws {
        self.config = config
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    public var url: URL { URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)/files/test.bin")! }
    public var requests: [RecordedRequest] { lock.withLock { recorded } }
    public var maxObservedConcurrency: Int { lock.withLock { observedMax } }
    public func update(_ change: (inout Config) -> Void) { lock.withLock { change(&config) } }

    public func start() async throws {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume() }
                case .failed(let error):
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    public func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readHead(connection, buffer: Data())
    }

    private func readHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                Task { await self.serve(connection, head: head) }
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.readHead(connection, buffer: buffer)
            }
        }
    }

    private func serve(_ connection: NWConnection, head: String) async {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = RecordedRequest(method: requestLine.first.map(String.init) ?? "",
                                      path: requestLine.count > 1 ? String(requestLine[1]) : "", headers: headers)
        let (cfg, forced, dropAfter) = lock.withLock { () -> (Config, Int?, Int?) in
            recorded.append(request)
            active += 1
            observedMax = max(observedMax, active)
            var forced: Int? = config.statusSequence.isEmpty ? nil : config.statusSequence.removeFirst()
            if forced == nil, let limit = config.maxConcurrentConnections, active > limit { forced = 429 }
            var drop: Int?
            if forced == nil, let bytes = config.dropOnceAfterBytes, !didDrop { didDrop = true; drop = bytes }
            return (config, forced, drop)
        }
        defer { lock.withLock { active -= 1 } }

        if let limit = cfg.refuseBeyond, lock.withLock({ active }) > limit {
            connection.cancel()
            return
        }
        // RFC 9110: an unsatisfiable range (e.g. bytes=0- on an empty file) gets 416, as nginx and S3 do.
        if cfg.supportsRange, let rangeHeader = headers["range"], ifRangeMatches(headers["if-range"], cfg),
           parseRange(rangeHeader, total: cfg.body.count) == nil {
            await send(connection, head: responseHead(416, ["Content-Range": "bytes */\(cfg.body.count)", "Content-Length": "0",
                                                           "Connection": "close"]), body: Data(), rate: nil, dropAfter: nil)
            return
        }
        if let forced {
            let body = Data("error \(forced)".utf8)
            await send(connection, head: responseHead(forced, ["Content-Length": "\(body.count)", "Connection": "close"]),
                       body: body, rate: nil, dropAfter: nil)
            return
        }

        var status = 200
        var slice = cfg.body
        var fields: [String: String] = ["Content-Type": cfg.contentType, "Connection": "close"]
        if cfg.supportsRange, let rangeHeader = headers["range"], ifRangeMatches(headers["if-range"], cfg),
           let range = parseRange(rangeHeader, total: cfg.body.count) {
            status = 206
            slice = cfg.body.subdata(in: range.lowerBound..<(range.upperBound + 1))
            fields["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(cfg.body.count)"
        }
        if cfg.sendContentLength { fields["Content-Length"] = "\(slice.count)" }
        if cfg.supportsRange { fields["Accept-Ranges"] = "bytes" }
        if let etag = cfg.etag { fields["ETag"] = etag }
        if let modified = cfg.lastModified { fields["Last-Modified"] = modified }
        if let disposition = cfg.contentDisposition { fields["Content-Disposition"] = disposition }
        await send(connection, head: responseHead(status, fields), body: slice,
                   rate: cfg.bytesPerSecondPerConnection, dropAfter: dropAfter ?? cfg.dropEveryAfterBytes)
    }

    private func parseRange(_ value: String, total: Int) -> ClosedRange<Int>? {
        guard value.hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard spec.count == 2, let start = Int(spec[0]), start < total else { return nil }
        let end = spec[1].isEmpty ? total - 1 : min(Int(spec[1]) ?? total - 1, total - 1)
        return end >= start ? start...end : nil
    }

    private func ifRangeMatches(_ value: String?, _ cfg: Config) -> Bool {
        guard let value else { return true }
        return value == cfg.etag || value == cfg.lastModified
    }

    private func send(_ connection: NWConnection, head: String, body: Data, rate: Int?, dropAfter: Int?) async {
        await write(connection, Data(head.utf8))
        let chunk = rate.map { max(1024, min(16 * 1024, $0 / 20)) } ?? 64 * 1024
        var offset = 0
        while offset < body.count {
            if let dropAfter, offset >= dropAfter { connection.cancel(); return }
            let count = min(chunk, body.count - offset)
            await write(connection, body.subdata(in: offset..<(offset + count)))
            offset += count
            if let rate { try? await Task.sleep(nanoseconds: UInt64(Double(count) / Double(rate) * 1_000_000_000)) }
        }
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func write(_ connection: NWConnection, _ data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    private func responseHead(_ status: Int, _ fields: [String: String]) -> String {
        let reasons = [200: "OK", 206: "Partial Content", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                       410: "Gone", 416: "Range Not Satisfiable", 429: "Too Many Requests",
                       500: "Internal Server Error", 503: "Service Unavailable"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Status")\r\n"
        for (name, value) in fields { head += "\(name): \(value)\r\n" }
        return head + "\r\n"
    }
}
