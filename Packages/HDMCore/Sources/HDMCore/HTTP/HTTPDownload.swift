import Foundation

public struct ResumeState: Sendable, Equatable {
    public var segments: [Segment]
    public var totalBytes: Int64
    public var etag: String?
    public var lastModified: String?

    public init(segments: [Segment], totalBytes: Int64, etag: String?, lastModified: String?) {
        self.segments = segments
        self.totalBytes = totalBytes
        self.etag = etag
        self.lastModified = lastModified
    }
}

public struct DownloadRequest: Sendable {
    public var url: URL
    public var headers: [String: String]
    public var partURL: URL
    public var resume: ResumeState?
    public var maxConnections: Int
    public var retryLimit: Int
    public var timeout: TimeInterval
    public var minSegment: Int64

    public init(url: URL, headers: [String: String] = [:], partURL: URL, resume: ResumeState? = nil,
                maxConnections: Int = 8, retryLimit: Int = 10, timeout: TimeInterval = 30, minSegment: Int64 = 1 << 20) {
        self.url = url
        self.headers = headers
        self.partURL = partURL
        self.resume = resume
        self.maxConnections = maxConnections
        self.retryLimit = retryLimit
        self.timeout = timeout
        self.minSegment = minSegment
    }
}

public struct ConnectionInfo: Sendable, Hashable, Identifiable {
    public var id: Int
    public var segmentIndex: Int
    public var receivedInSegment: Int64
    public var isReceiving: Bool
}

public struct DownloadSnapshot: Sendable {
    public var segments: [Segment]
    public var receivedBytes: Int64
    public var totalBytes: Int64?
    public var connections: [ConnectionInfo]
}

public enum DownloadEvent: Sendable {
    case probed(ProbeResult)
    case progress(DownloadSnapshot)
    case finished(totalBytes: Int64)
    case failed(FailureReason)
    case needsRefresh(statusCode: Int)
}

/// Transfers one URL into its `.hdmpart` file using dynamic segmentation (spec §5.3–5.5).
/// Renaming the finished file is the caller's job.
public actor HTTPDownload {
    private enum State { case idle, running, stopping, finished }

    public nonisolated let events: AsyncStream<DownloadEvent>
    private let continuation: AsyncStream<DownloadEvent>.Continuation
    private let request: DownloadRequest
    private let planner: SegmentPlanner
    private let limiters: [SpeedLimiter]
    private let backoff: @Sendable (Int) -> TimeInterval

    private var state = State.idle
    private var table: SegmentTable?
    private var connections: [Int: Connection] = [:]
    private var slotSegment: [Int: Int] = [:]
    private var receiving: Set<Int> = []
    private var retryCounted: Set<Int> = []
    private var nextSlot = 1
    private var probeSlot: Int?
    private var probed = false
    private var total: Int64?
    private var resumable = false
    private var ifRange: String?
    private var isResume = false
    private var resumeConfirmed = false
    private var maxConnections: Int
    private var failures: [Int: Int] = [:]
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var ticker: Task<Void, Never>?

    public init(request: DownloadRequest, limiters: [SpeedLimiter] = [],
                backoff: @escaping @Sendable (Int) -> TimeInterval = RetryPolicy.delay(forAttempt:)) {
        self.request = request
        self.planner = SegmentPlanner(minSegment: request.minSegment)
        self.limiters = limiters
        self.backoff = backoff
        self.maxConnections = max(1, request.maxConnections)
        let pair = AsyncStream.makeStream(of: DownloadEvent.self, bufferingPolicy: .unbounded)
        self.events = pair.stream
        self.continuation = pair.continuation
    }

    public func start() {
        guard state == .idle else { return }
        state = .running
        do {
            let fm = FileManager.default
            if let resume = request.resume, !resume.segments.isEmpty, fm.fileExists(atPath: request.partURL.path) {
                let file = try PartFile(url: request.partURL)
                try file.resize(atLeast: resume.totalBytes)
                table = SegmentTable(segments: resume.segments, planner: planner, file: file)
                total = resume.totalBytes
                resumable = true
                probed = true
                isResume = true
                ifRange = resume.etag ?? resume.lastModified
            } else {
                try? fm.removeItem(at: request.partURL)
                table = SegmentTable(segments: [Segment(start: 0, end: .max)], planner: planner,
                                     file: try PartFile(url: request.partURL))
            }
        } catch {
            fail(.fileSystem(error.localizedDescription))
            return
        }
        startTicker()
        if table?.allComplete == true { finish(); return }
        fillConnections()
    }

    /// Stops all connections and returns the exact segment state for persistence.
    public func pause() async -> [Segment] {
        if state == .running {
            state = .stopping
            ticker?.cancel()
            connections.values.forEach { $0.cancel() }
            if !connections.isEmpty {
                await withCheckedContinuation { drainWaiters.append($0) }
            }
            state = .finished
            table?.closeFile()
            continuation.finish()
        }
        return table?.snapshot() ?? []
    }

    public func cancel() {
        guard state == .running || state == .idle else { return }
        state = .finished
        ticker?.cancel()
        connections.values.forEach { $0.cancel() }
        if connections.isEmpty { table?.closeFile() }
        continuation.finish()
    }

    // MARK: - Connections

    private func fillConnections() {
        guard state == .running, let table else { return }
        if !probed {
            if connections.isEmpty {
                table.claim(0)
                probeSlot = open(segment: 0, from: 0, to: .max)
            }
            return
        }
        if !resumable {
            // A non-resumable transfer can only restart from byte 0 with a single connection.
            if connections.isEmpty {
                table.replace(with: [Segment(start: 0, end: total ?? .max)])
                probed = false
                fillConnections()
            }
            return
        }
        while connections.count < maxConnections, let index = table.claimNext() {
            let segment = table.segment(index)
            open(segment: index, from: segment.cursor, to: segment.end)
        }
    }

    @discardableResult
    private func open(segment index: Int, from start: Int64, to end: Int64) -> Int {
        let slot = nextSlot
        nextSlot += 1
        guard let table else { return slot }
        var urlRequest = URLRequest(url: request.url)
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.setValue(end == .max ? "bytes=\(start)-" : "bytes=\(start)-\(end - 1)", forHTTPHeaderField: "Range")
        urlRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if probed, let ifRange { urlRequest.setValue(ifRange, forHTTPHeaderField: "If-Range") }
        let handlers = ConnectionHandlers(
            onResponse: { [weak self] response in
                await self?.handleResponse(slot: slot, response: response) ?? false
            },
            onData: { data in
                do {
                    return try table.write(data, segment: index) == .segmentDone ? .done : .more
                } catch PartFileError.diskFull {
                    return .failed(.diskFull)
                } catch {
                    return .failed(.fileSystem(String(describing: error)))
                }
            },
            onComplete: { [weak self] result in
                Task { await self?.connectionFinished(slot: slot, result: result) }
            })
        let connection = Connection(request: urlRequest, timeout: request.timeout, limiters: limiters, handlers: handlers)
        connections[slot] = connection
        slotSegment[slot] = index
        connection.start()
        return slot
    }

    private func handleResponse(slot: Int, response: HTTPURLResponse) -> Bool {
        guard state == .running, let table, let index = slotSegment[slot] else { return false }
        let status = response.statusCode
        let isProbe = slot == probeSlot
        switch status {
        case 206:
            if isProbe {
                let info = ProbeResult(response: response)
                probed = true
                total = info.totalBytes
                resumable = info.resumable
                ifRange = info.ifRangeValidator
                if let total {
                    do { try table.resize(atLeast: total) } catch {
                        fail(.fileSystem(error.localizedDescription))
                        return false
                    }
                    table.replace(with: planner.initialSegments(total: total, connections: maxConnections))
                }
                continuation.yield(.probed(info))
                receiving.insert(slot)
                fillConnections()
                return true
            }
            let range = ContentRange(header: response.value(forHTTPHeaderField: "Content-Range"))
            guard let range, range.start == table.segment(index).cursor, range.total == nil || range.total == total else {
                fail(.serverFileChanged)
                return false
            }
            resumeConfirmed = true
            receiving.insert(slot)
            return true
        case 200:
            if isProbe {
                let info = ProbeResult(response: response)
                probed = true
                resumable = false
                total = info.totalBytes
                ifRange = nil
                table.replace(with: [Segment(start: 0, end: total ?? .max)])
                if let total { try? table.resize(atLeast: total) }
                continuation.yield(.probed(info))
                receiving.insert(slot)
                return true
            }
            if isResume && !resumeConfirmed {
                fail(.serverFileChanged)   // If-Range did not match: the file changed on the server
                return false
            }
            if connections.count <= 1 { retryCounted.insert(slot) }
            maxConnections = max(1, connections.count - 1)
            return false
        case 401:
            fail(.authRequired)
            return false
        case 403, 404, 410:
            stopForRefresh(status)
            return false
        case 416:
            fail(.serverFileChanged)
            return false
        case 429, 503:
            if connections.count > 1 {
                maxConnections = max(1, connections.count - 1)
            } else {
                retryCounted.insert(slot)
            }
            return false
        case 500...599:
            retryCounted.insert(slot)
            return false
        default:
            fail(.http(status))
            return false
        }
    }

    private func connectionFinished(slot: Int, result: ConnectionResult) {
        guard let index = slotSegment.removeValue(forKey: slot) else { return }
        connections.removeValue(forKey: slot)
        receiving.remove(slot)
        let countsAsFailure = retryCounted.remove(slot) != nil
        if slot == probeSlot { probeSlot = nil }
        table?.release(index)
        defer { if connections.isEmpty { drain() } }
        guard state == .running, let table else { return }

        switch result {
        case .segmentDone:
            failures[index] = 0
        case .endOfStream:
            if table.segment(index).isOpenEnded {
                table.closeOpenEnded(index)
                total = table.receivedBytes
            } else if !table.segment(index).isComplete {
                registerFailure(index, message: "The server closed the connection early.")
                return
            }
        case .cancelled:
            break
        case .rejected:
            if countsAsFailure {
                registerFailure(index, message: "The server is busy.")
                return
            }
        case .fatal(let reason):
            fail(reason)
            return
        case .failed(let message):
            registerFailure(index, message: message)
            return
        }
        if table.allComplete { finish() } else { fillConnections() }
    }

    private func registerFailure(_ index: Int, message: String) {
        let attempt = (failures[index] ?? 0) + 1
        failures[index] = attempt
        guard attempt <= request.retryLimit else {
            fail(.network(message))
            return
        }
        let delay = backoff(attempt)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.retryAfterBackoff()
        }
    }

    private func retryAfterBackoff() { fillConnections() }

    private func drain() {
        if state != .running { table?.closeFile() }
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    // MARK: - Terminal states

    private func finish() {
        guard state == .running else { return }
        stopEverything()
        continuation.yield(.finished(totalBytes: total ?? table?.receivedBytes ?? 0))
        continuation.finish()
    }

    private func fail(_ reason: FailureReason) {
        guard state == .running else { return }
        stopEverything()
        continuation.yield(.failed(reason))
        continuation.finish()
    }

    private func stopForRefresh(_ status: Int) {
        guard state == .running else { return }
        stopEverything()
        continuation.yield(.needsRefresh(statusCode: status))
        continuation.finish()
    }

    /// Emits a last snapshot (so the caller can persist it) and tears down connections.
    /// The file is closed once every connection has reported back (see `drain`).
    private func stopEverything() {
        state = .finished
        ticker?.cancel()
        emitProgress()
        connections.values.forEach { $0.cancel() }
        if connections.isEmpty { table?.closeFile() }
    }

    // MARK: - Progress

    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                await self.emitProgress()
            }
        }
    }

    private func emitProgress() {
        guard let table else { return }
        let segments = table.snapshot()
        let infos = slotSegment.sorted { $0.key < $1.key }.map { slot, index in
            ConnectionInfo(id: slot, segmentIndex: index,
                           receivedInSegment: index < segments.count ? segments[index].received : 0,
                           isReceiving: receiving.contains(slot))
        }
        continuation.yield(.progress(DownloadSnapshot(segments: segments, receivedBytes: segments.reduce(0) { $0 + $1.received },
                                                      totalBytes: total, connections: infos)))
    }
}
