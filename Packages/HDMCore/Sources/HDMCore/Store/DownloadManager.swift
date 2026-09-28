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
    public var media: MediaJob?

    public init(url: URL, fileName: String, directory: URL, category: DownloadCategory, headers: [String: String] = [:],
                pageURL: URL? = nil, referrer: URL? = nil, totalBytes: Int64? = nil, description: String = "",
                autoStart: Bool = true, media: MediaJob? = nil) {
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
        self.media = media
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
        /// Identifies this run, so late events or a pause of an older run never touch a newer one.
        let generation: Int
        var meter = SpeedMeter()
        var task: Task<Void, Never>?
    }

    private struct MediaRunning {
        let engine: MediaEngine
        let generation: Int
        var meter = SpeedMeter()
        var task: Task<Void, Never>?
    }

    @ObservationIgnored private let store: DownloadStore
    @ObservationIgnored private var running: [UUID: Running] = [:]
    @ObservationIgnored private var mediaRunning: [UUID: MediaRunning] = [:]
    @ObservationIgnored private var nextGeneration = 0
    @ObservationIgnored private let globalLimiter = SpeedLimiter(bytesPerSecond: 0)
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var networkWasSatisfied: Bool?
    @ObservationIgnored private let minSegment: Int64
    @ObservationIgnored private let backoff: @Sendable (Int) -> TimeInterval
    /// Where yt-dlp/ffmpeg/deno live; injectable so tests can point at a stub binary.
    @ObservationIgnored private let mediaTools: @Sendable () -> ComponentPaths

    public init(store: DownloadStore, settings: SettingsStore, minSegment: Int64 = 1 << 20,
                backoff: @escaping @Sendable (Int) -> TimeInterval = RetryPolicy.delay(forAttempt:),
                mediaTools: @escaping @Sendable () -> ComponentPaths = ComponentLocator.locate) {
        self.store = store
        self.settings = settings
        self.minSegment = minSegment
        self.backoff = backoff
        self.mediaTools = mediaTools
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
        let fileName: String
        if let job = new.media {
            // yt-dlp owns the extension (`base.%(ext)s`); uniqueness is reserved on the base name.
            let base = (FilenameResolver.sanitize(new.fileName) as NSString).deletingPathExtension
            fileName = reserveMediaName(base, in: new.directory) + "." + (job.audioOnly ? "m4a" : "mp4")
        } else {
            fileName = reserveName(FilenameResolver.sanitize(new.fileName), in: new.directory)
        }
        let item = DownloadItem(url: new.url, fileName: fileName, saveDirectory: new.directory,
                                category: new.category, headers: new.headers, pageURL: new.pageURL, referrer: new.referrer,
                                totalBytes: new.totalBytes, userDescription: new.description, autoStart: new.autoStart,
                                media: new.media)
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
                // Redownload/refresh may have started a new run while we waited; leave that run alone.
                guard running[id] == nil, item(id)?.status.isRunning == true else { continue }
                update(id) { item in
                    item.segments = segments
                    item.receivedBytes = segments.reduce(0) { $0 + $1.received }
                    item.status = .paused
                }
            } else if let run = mediaRunning.removeValue(forKey: id) {
                run.task?.cancel()
                live[id] = nil
                await run.engine.pause()   // SIGINT; yt-dlp flushes its `.part` files before exiting
                guard mediaRunning[id] == nil, item(id)?.status.isRunning == true else { continue }
                update(id) { $0.status = .paused }
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

    /// Called on quit: stops running transfers and saves their exact state. Queued items stay queued.
    public func prepareForTermination() async {
        let busy = items.filter { running[$0.id] != nil || mediaRunning[$0.id] != nil }.map(\.id)
        await pause(busy)
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
            if let run = mediaRunning.removeValue(forKey: id) {
                run.task?.cancel()
                Task { await run.engine.cancel() }
            }
            live[id] = nil
            guard let item = item(id) else { continue }
            try? fm.removeItem(at: item.partURL)
            removeMediaArtifacts(of: item)
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
        live[id] = nil
        if let run = running.removeValue(forKey: id) {
            run.task?.cancel()
            Task { await run.download.cancel() }
            update(id) { item in
                try? FileManager.default.removeItem(at: item.partURL)
                item.resetTransfer()
                item.status = .queued
                item.autoStart = true
            }
            scheduleSave()
            schedule()
        } else if let run = mediaRunning.removeValue(forKey: id) {
            // Hold the item paused until the old process is dead, or two yt-dlp runs would share one `.part`.
            run.task?.cancel()
            update(id) { item in
                item.resetTransfer()
                item.status = .paused
            }
            Task { [weak self] in
                await run.engine.cancel()
                self?.redownloadMediaAfterCancel(id)
            }
        } else {
            update(id) { item in
                try? FileManager.default.removeItem(at: item.partURL)
                removeMediaFiles(of: item)
                item.resetTransfer()
                item.status = .queued
                item.autoStart = true
            }
            scheduleSave()
            schedule()
        }
    }

    private func redownloadMediaAfterCancel(_ id: UUID) {
        guard item(id) != nil else { return }
        update(id) { item in
            removeMediaFiles(of: item)   // yt-dlp would otherwise treat the old file as "already downloaded"
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

    /// Sets or replaces one request header (e.g. `Authorization` after a 401) for the next attempt.
    public func setHeader(_ id: UUID, name: String, value: String) {
        update(id) { $0.headers[name] = value }
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

    /// Two unfinished items with the same name would share one `.hdmpart`; give the newcomer `name (2)`.
    /// An existing *finished* file is left to the conflict policy at completion.
    private func reserveName(_ name: String, in directory: URL) -> String {
        let fm = FileManager.default
        let dir = directory.standardizedFileURL
        return FilenameResolver.uniqueName(name) { candidate in
            items.contains { $0.status != .completed && $0.fileName == candidate && $0.saveDirectory.standardizedFileURL == dir }
                || fm.fileExists(atPath: dir.appendingPathComponent(candidate).path + ".hdmpart")
        }
    }

    /// Media names are unique on the extension-less base: `Title`, `Title (2)`, … so that
    /// `Title.f137.mp4.part` and `Title.mp4` of two jobs never collide.
    private func reserveMediaName(_ base: String, in directory: URL) -> String {
        let fm = FileManager.default
        let dir = directory.standardizedFileURL
        return FilenameResolver.uniqueName(base) { candidate in
            let ownBase = { (name: String) in (name as NSString).deletingPathExtension }
            if items.contains(where: { $0.saveDirectory.standardizedFileURL == dir && ownBase($0.fileName) == candidate }) {
                return true
            }
            guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
            return entries.contains { $0.hasPrefix(candidate + ".") }
        }
    }

    // MARK: Scheduling

    private func schedule() {
        let limit = max(1, settings.settings.maxConcurrentDownloads)
        for index in items.indices where running.count < limit {
            let item = items[index]
            guard item.status == .queued, item.autoStart || queueRunning, running[item.id] == nil else { continue }
            start(index)
        }
        if queueRunning, !items.contains(where: { $0.status == .queued && !$0.autoStart }) {
            queueRunning = false   // every queued item has started; later "Download Later" items wait again
        }
    }

    private func start(_ index: Int) {
        let item = items[index]
        if item.kind == .media, let job = item.media {
            startMedia(index, job: job)
            return
        }
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
        nextGeneration += 1
        let generation = nextGeneration
        var run = Running(download: download, limiter: limiter, generation: generation)
        run.task = Task { [weak self] in
            for await event in download.events { self?.handle(event, for: id, generation: generation) }
        }
        running[id] = run
        onEvent?(.started(id))
        Task { await download.start() }
    }

    private func startMedia(_ index: Int, job: MediaJob) {
        let item = items[index]
        let tools = mediaTools()
        guard let ytDLP = tools.ytDLP, FileManager.default.isExecutableFile(atPath: ytDLP.path) else {
            items[index].status = .failed(.media("yt-dlp could not be found. Install it with: brew install yt-dlp"))
            flush()
            onEvent?(.failed(item.id))
            return
        }
        if job.audioOnly, tools.ffmpeg == nil {
            items[index].status = .failed(.media("ffmpeg is required for audio extraction. Install it with: brew install ffmpeg"))
            flush()
            onEvent?(.failed(item.id))
            return
        }
        do {
            try FileManager.default.createDirectory(at: item.saveDirectory, withIntermediateDirectories: true)
        } catch {
            items[index].status = .failed(.fileSystem(error.localizedDescription))
            return
        }
        if let total = item.totalBytes, total > 0, Self.freeDiskSpace(on: item.saveDirectory) < total {
            items[index].status = .failed(.diskFull)
            flush()
            onEvent?(.failed(item.id))
            return
        }
        // One `-r` value instead of the HTTP stack of limiters; changes apply on the next run.
        let global = settings.settings.globalSpeedLimit
        let perItem = item.speedLimit ?? 0
        let limit = global > 0 && perItem > 0 ? min(global, perItem) : max(global, perItem)
        let request = MediaRequest(
            sourceURL: job.sourceURL, formatSelector: job.formatSelector, sortSpec: job.sortSpec,
            audioOnly: job.audioOnly, directory: item.saveDirectory,
            baseName: (item.fileName as NSString).deletingPathExtension,
            approxTotalBytes: item.totalBytes, headers: job.headers, tools: tools,
            concurrentFragments: max(1, settings.settings.maxConnections), speedLimitBytesPerSecond: limit)
        let engine = MediaEngine(request: request)
        items[index].status = .connecting
        items[index].lastTryAt = Date()
        items[index].resumable = true
        let id = item.id
        nextGeneration += 1
        let generation = nextGeneration
        var run = MediaRunning(engine: engine, generation: generation)
        run.task = Task { [weak self] in
            for await event in engine.events { self?.handleMedia(event, for: id, generation: generation) }
        }
        mediaRunning[id] = run
        onEvent?(.started(id))
        Task { await engine.start() }
    }

    private func handleMedia(_ event: MediaEvent, for id: UUID, generation: Int) {
        guard mediaRunning[id]?.generation == generation, let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .progress(let received, let total):
            items[index].receivedBytes = received
            if let total { items[index].totalBytes = total }
            if items[index].status == .connecting { items[index].status = .downloading }
            mediaRunning[id]?.meter.add(bytes: received, at: ProcessInfo.processInfo.systemUptime)
            let meter = mediaRunning[id]?.meter ?? SpeedMeter()
            live[id] = LiveStats(bytesPerSecond: meter.bytesPerSecond,
                                 secondsRemaining: meter.secondsRemaining(total: items[index].totalBytes, received: received),
                                 connections: [])
            scheduleSave()
        case .postProcessing:
            items[index].status = .merging
            live[id] = nil
            flush()
        case .finished(let path, let total):
            mediaRunning[id] = nil
            live[id] = nil
            if let path {
                items[index].fileName = path.lastPathComponent
                items[index].saveDirectory = path.deletingLastPathComponent()
                if total > 0 { items[index].totalBytes = total }
                items[index].receivedBytes = total > 0 ? total : items[index].receivedBytes
            } else if total > 0 {
                items[index].receivedBytes = total
            }
            finalizeMedia(index)
            schedule()
        case .failed(let reason):
            mediaRunning[id] = nil
            live[id] = nil
            items[index].status = .failed(reason)
            flush()
            onEvent?(.failed(id))
            schedule()
        }
    }

    private func finalizeMedia(_ index: Int) {
        var item = items[index]
        Self.markQuarantined(item.fileURL, source: item.url, page: item.pageURL ?? item.referrer)
        item.status = .completed
        item.completedAt = Date()
        item.awaitingRefresh = false
        if let size = try? item.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, Int64(size) > item.receivedBytes {
            item.totalBytes = Int64(size)
            item.receivedBytes = Int64(size)
        }
        items[index] = item
        flush()
        onEvent?(.completed(item.id))
    }

    /// yt-dlp's partial files for one job: `base.f137.mp4.part`, `base.mp4.part`, `base.ytdl`, …
    private func removeMediaArtifacts(of item: DownloadItem) {
        guard item.kind == .media else { return }
        let fm = FileManager.default
        let base = (item.fileName as NSString).deletingPathExtension
        guard let entries = try? fm.contentsOfDirectory(atPath: item.saveDirectory.path) else { return }
        for entry in entries where entry.hasPrefix(base + ".") {
            let ext = (entry as NSString).pathExtension.lowercased()
            if ext == "part" || ext == "ytdl" || ext == "temp" || ext.hasPrefix("part-") {
                try? fm.removeItem(at: item.saveDirectory.appendingPathComponent(entry))
            }
        }
    }

    /// All files of a media job, finished ones included (used by redownload).
    private func removeMediaFiles(of item: DownloadItem) {
        guard item.kind == .media else { return }
        let fm = FileManager.default
        let base = (item.fileName as NSString).deletingPathExtension
        guard let entries = try? fm.contentsOfDirectory(atPath: item.saveDirectory.path) else { return }
        for entry in entries where entry.hasPrefix(base + ".") {
            try? fm.removeItem(at: item.saveDirectory.appendingPathComponent(entry))
        }
    }

    private static func freeDiskSpace(on url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? .max
    }

    private func handle(_ event: DownloadEvent, for id: UUID, generation: Int) {
        guard running[id]?.generation == generation, let index = items.firstIndex(where: { $0.id == id }) else { return }
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
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: item.fileURL.path, isDirectory: &isDirectory) {
            if settings.settings.conflictPolicy == .overwrite, !isDirectory.boolValue,
               (try? fm.trashItem(at: item.fileURL, resultingItemURL: nil)) != nil {
                // replaced: the old file is in the Trash, not deleted
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
