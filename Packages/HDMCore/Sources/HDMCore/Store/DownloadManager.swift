import CoreServices
import Foundation
import Network
import Observation

public struct NewDownload: Sendable {
    public var url: URL
    public var fileName: String
    public var directory: URL
    public var category: DownloadCategory
    public var headers: [String: String]
    public var pageURL: URL?
    public var referrer: URL?
    public var totalBytes: Int64?
    public var description: String
    public var autoStart: Bool

    public init(url: URL, fileName: String, directory: URL, category: DownloadCategory, headers: [String: String] = [:],
                pageURL: URL? = nil, referrer: URL? = nil, totalBytes: Int64? = nil, description: String = "",
                autoStart: Bool = true) {
        self.url = url
        self.fileName = fileName
        self.directory = directory
        self.category = category
        self.headers = headers
        self.pageURL = pageURL
        self.referrer = referrer
        self.totalBytes = totalBytes
        self.description = description
        self.autoStart = autoStart
    }
}

public struct LiveStats: Sendable, Equatable {
    public var bytesPerSecond: Double = 0
    public var secondsRemaining: TimeInterval?
    public var connections: [ConnectionInfo] = []
}

public enum ManagerEvent: Sendable {
    case started(UUID)
    case completed(UUID)
    case failed(UUID)
    case needsRefresh(UUID)
}

/// Owns the download list: queueing, starting/stopping `HTTPDownload`s, persistence and finalisation.
@MainActor @Observable
public final class DownloadManager {
    public private(set) var items: [DownloadItem] = []
    public private(set) var live: [UUID: LiveStats] = [:]
    public private(set) var queueRunning = false
    public let settings: SettingsStore
    @ObservationIgnored public var onEvent: ((ManagerEvent) -> Void)?

    private struct Running {
        let download: HTTPDownload
        let limiter: SpeedLimiter
        var meter = SpeedMeter()
        var task: Task<Void, Never>?
    }

    @ObservationIgnored private let store: DownloadStore
    @ObservationIgnored private var running: [UUID: Running] = [:]
    @ObservationIgnored private let globalLimiter = SpeedLimiter(bytesPerSecond: 0)
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var networkWasSatisfied: Bool?
    @ObservationIgnored private let minSegment: Int64
    @ObservationIgnored private let backoff: @Sendable (Int) -> TimeInterval

    public init(store: DownloadStore, settings: SettingsStore, minSegment: Int64 = 1 << 20,
                backoff: @escaping @Sendable (Int) -> TimeInterval = RetryPolicy.delay(forAttempt:)) {
        self.store = store
        self.settings = settings
        self.minSegment = minSegment
        self.backoff = backoff
        items = store.load().map { item in
            var item = item
            if item.status.isRunning { item.status = .paused }
            return item
        }
        globalLimiter.setRate(settings.settings.globalSpeedLimit)
        settings.onChange = { [weak self] new in self?.settingsChanged(new) }
        startNetworkMonitor()
        schedule()
    }

    // MARK: Queries

    public func item(_ id: UUID) -> DownloadItem? { items.first { $0.id == id } }
    public var totalBytesPerSecond: Double { live.values.reduce(0) { $0 + $1.bytesPerSecond } }
    public var activeCount: Int { items.filter { $0.status.isRunning }.count }

    public var overallFraction: Double? {
        let active = items.filter { $0.status.isRunning }
        let totals = active.compactMap(\.totalBytes)
        guard !active.isEmpty, totals.count == active.count else { return nil }
        let total = totals.reduce(0, +)
        return total > 0 ? Double(active.reduce(0) { $0 + $1.receivedBytes }) / Double(total) : nil
    }

    /// A download waiting for a new link whose name or size matches a newly captured one (spec §5.5).
    public func refreshCandidate(fileName: String, totalBytes: Int64?) -> DownloadItem? {
        items.first { item in
            guard item.awaitingRefresh || item.status == .needsRefresh else { return false }
            if let totalBytes, let known = item.totalBytes, totalBytes == known { return true }
            return item.fileName == fileName
        }
    }

    // MARK: Commands

    @discardableResult
    public func add(_ new: NewDownload) -> UUID {
        let item = DownloadItem(url: new.url, fileName: FilenameResolver.sanitize(new.fileName), saveDirectory: new.directory,
                                category: new.category, headers: new.headers, pageURL: new.pageURL, referrer: new.referrer,
                                totalBytes: new.totalBytes, userDescription: new.description, autoStart: new.autoStart)
        items.append(item)
        scheduleSave()
        schedule()
        return item.id
    }

    public func resume(_ ids: some Sequence<UUID>) {
        for id in ids {
            update(id) { item in
                guard item.status.canResume || item.status == .queued else { return }
                item.status = .queued
                item.autoStart = true
            }
        }
        scheduleSave()
        schedule()
    }

    public func addToQueue(_ ids: some Sequence<UUID>) {
        for id in ids {
            update(id) { item in
                guard item.status.canResume || item.status == .queued else { return }
                item.status = .queued
                item.autoStart = false
            }
        }
        scheduleSave()
    }

    public func pause(_ ids: some Sequence<UUID>) async {
        for id in Array(ids) {
            if let run = running.removeValue(forKey: id) {
                run.task?.cancel()
                live[id] = nil
                let segments = await run.download.pause()
                update(id) { item in
                    item.segments = segments
                    item.receivedBytes = segments.reduce(0) { $0 + $1.received }
                    item.status = .paused
                }
            } else {
                update(id) { if $0.status == .queued { $0.status = .paused } }
            }
        }
        flush()
        schedule()
    }

    public func pauseAll() async {
        await pause(items.filter { $0.status.isRunning || $0.status == .queued }.map(\.id))
    }

    /// Called on quit: stops running transfers and saves their exact segments. Queued items stay queued.
    public func prepareForTermination() async {
        await pause(items.filter { running[$0.id] != nil }.map(\.id))
        flush()
    }

    public func startQueue() {
        queueRunning = true
        schedule()
    }

    public func stopQueue() { queueRunning = false }

    public func remove(_ ids: Set<UUID>, deleteFiles: Bool) {
        let fm = FileManager.default
        for id in ids {
            if let run = running.removeValue(forKey: id) {
                run.task?.cancel()
                Task { await run.download.cancel() }
            }
            live[id] = nil
            guard let item = item(id) else { continue }
            try? fm.removeItem(at: item.partURL)
            if deleteFiles, item.status == .completed {
                try? fm.trashItem(at: item.fileURL, resultingItemURL: nil)
            }
        }
        items.removeAll { ids.contains($0.id) }
        flush()
        schedule()
    }

    public func removeCompleted() {
        remove(Set(items.filter { $0.status == .completed }.map(\.id)), deleteFiles: false)
    }

    public func redownload(_ id: UUID) {
        if let run = running.removeValue(forKey: id) {
            run.task?.cancel()
            Task { await run.download.cancel() }
        }
        live[id] = nil
        update(id) { item in
            try? FileManager.default.removeItem(at: item.partURL)
            item.resetTransfer()
            item.status = .queued
            item.autoStart = true
        }
        scheduleSave()
        schedule()
    }

    public func setSpeedLimit(_ id: UUID, bytesPerSecond: Int64?) {
        update(id) { $0.speedLimit = bytesPerSecond }
        running[id]?.limiter.setRate(bytesPerSecond ?? 0)
        scheduleSave()
    }

    public func setOnComplete(_ id: UUID, _ action: CompletionAction) {
        update(id) { $0.onComplete = action }
        scheduleSave()
    }

    public func markAwaitingRefresh(_ id: UUID) {
        update(id) { $0.awaitingRefresh = true }
        scheduleSave()
    }

    public func applyRefreshedLink(_ id: UUID, url: URL, headers: [String: String], pageURL: URL?, referrer: URL?) {
        if let run = running.removeValue(forKey: id) {
            run.task?.cancel()
            Task { await run.download.cancel() }
        }
        update(id) { item in
            item.url = url
            item.headers = headers
            item.pageURL = pageURL ?? item.pageURL
            item.referrer = referrer ?? item.referrer
            item.awaitingRefresh = false
            item.status = .queued
            item.autoStart = true
        }
        scheduleSave()
        schedule()
    }

    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        do { try store.save(items) } catch { NSLog("HDM: could not save downloads: \(error)") }
    }

    // MARK: Scheduling

    private func schedule() {
        let limit = max(1, settings.settings.maxConcurrentDownloads)
        for index in items.indices where running.count < limit {
            let item = items[index]
            guard item.status == .queued, item.autoStart || queueRunning, running[item.id] == nil else { continue }
            start(index)
        }
    }

    private func start(_ index: Int) {
        let item = items[index]
        let s = settings.settings
        var resume: ResumeState?
        if item.resumable == true, let total = item.totalBytes, !item.segments.isEmpty {
            resume = ResumeState(segments: item.segments, totalBytes: total, etag: item.etag, lastModified: item.lastModified)
        }
        do {
            try FileManager.default.createDirectory(at: item.saveDirectory, withIntermediateDirectories: true)
        } catch {
            items[index].status = .failed(.fileSystem(error.localizedDescription))
            return
        }
        let limiter = SpeedLimiter(bytesPerSecond: item.speedLimit ?? 0)
        let download = HTTPDownload(
            request: DownloadRequest(url: item.url, headers: item.headers, partURL: item.partURL, resume: resume,
                                     maxConnections: item.maxConnections ?? s.maxConnections, retryLimit: s.retryCount,
                                     timeout: s.timeoutSeconds, minSegment: minSegment),
            limiters: [globalLimiter, limiter], backoff: backoff)
        items[index].status = .connecting
        items[index].lastTryAt = Date()
        if resume == nil {
            items[index].segments = []
            items[index].receivedBytes = 0
        }
        let id = item.id
        var run = Running(download: download, limiter: limiter)
        run.task = Task { [weak self] in
            for await event in download.events { self?.handle(event, for: id) }
        }
        running[id] = run
        onEvent?(.started(id))
        Task { await download.start() }
    }

    private func handle(_ event: DownloadEvent, for id: UUID) {
        guard running[id] != nil, let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .probed(let probe):
            items[index].totalBytes = probe.totalBytes
            items[index].resumable = probe.resumable
            items[index].etag = probe.etag
            items[index].lastModified = probe.lastModified
            items[index].finalURL = probe.finalURL
        case .progress(let snapshot):
            items[index].segments = snapshot.segments
            items[index].receivedBytes = snapshot.receivedBytes
            if let total = snapshot.totalBytes { items[index].totalBytes = total }
            if items[index].status == .connecting, snapshot.receivedBytes > 0 || snapshot.connections.contains(where: \.isReceiving) {
                items[index].status = .downloading
            }
            running[id]?.meter.add(bytes: snapshot.receivedBytes, at: ProcessInfo.processInfo.systemUptime)
            let meter = running[id]?.meter ?? SpeedMeter()
            live[id] = LiveStats(bytesPerSecond: meter.bytesPerSecond,
                                 secondsRemaining: meter.secondsRemaining(total: items[index].totalBytes, received: snapshot.receivedBytes),
                                 connections: snapshot.connections)
            scheduleSave()
        case .finished(let total):
            running[id] = nil
            live[id] = nil
            items[index].totalBytes = total
            items[index].receivedBytes = total
            finalize(index)
            schedule()
        case .failed(let reason):
            running[id] = nil
            live[id] = nil
            items[index].status = .failed(reason)
            flush()
            onEvent?(.failed(id))
            schedule()
        case .needsRefresh:
            running[id] = nil
            live[id] = nil
            items[index].status = .needsRefresh
            flush()
            onEvent?(.needsRefresh(id))
            schedule()
        }
    }

    private func finalize(_ index: Int) {
        var item = items[index]
        let fm = FileManager.default
        let part = item.partURL   // captured before a rename changes the derived path
        if fm.fileExists(atPath: item.fileURL.path) {
            if settings.settings.conflictPolicy == .overwrite {
                try? fm.removeItem(at: item.fileURL)
            } else {
                item.fileName = FilenameResolver.uniqueName(item.fileName, in: item.saveDirectory)
            }
        }
        do {
            try fm.moveItem(at: part, to: item.fileURL)
            Self.markQuarantined(item.fileURL, source: item.url, page: item.pageURL ?? item.referrer)
            item.status = .completed
            item.completedAt = Date()
            item.awaitingRefresh = false
        } catch {
            item.status = .failed(.fileSystem(error.localizedDescription))
        }
        items[index] = item
        flush()
        onEvent?(item.status == .completed ? .completed(item.id) : .failed(item.id))
    }

    /// Same Gatekeeper treatment browsers give downloaded files (spec §10).
    private static func markQuarantined(_ url: URL, source: URL, page: URL?) {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Hiz Download Manager",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineDataURLKey as String: source,
        ]
        if let page { properties[kLSQuarantineOriginURLKey as String] = page }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var target = url
        try? target.setResourceValues(values)
    }

    // MARK: Helpers

    private func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func settingsChanged(_ new: AppSettings) {
        globalLimiter.setRate(new.globalSpeedLimit)
        schedule()
    }

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(satisfied: satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "hdm.path"))
    }

    /// When the network comes back, downloads that failed with a network error are retried.
    private func networkChanged(satisfied: Bool) {
        defer { networkWasSatisfied = satisfied }
        guard satisfied, networkWasSatisfied == false else { return }
        var changed = false
        for index in items.indices {
            if case .failed(.network) = items[index].status {
                items[index].status = .queued
                items[index].autoStart = true
                changed = true
            }
        }
        if changed {
            scheduleSave()
            schedule()
        }
    }
}
