import Foundation
import HDMCore
import HDMIPC
import Observation

/// Owns the IPC socket: translates browser-extension messages into captures, dialogs and media
/// downloads (spec §7.1), and tracks per-browser "last seen" for the settings tab.
@MainActor @Observable
final class BrowserCoordinator {
    struct MediaQueryEntry {
        let sourceURL: URL
        let headers: [String: String]
        let title: String
        let options: [MediaFormatOption]
    }

    private(set) var lastSeen: [String: Date] = [:]
    @ObservationIgnored private var servers: [IPCServer] = []
    @ObservationIgnored private var groupServerBound = false
    @ObservationIgnored private var groupRetry: Timer?
    @ObservationIgnored private var queries: [String: MediaQueryEntry] = [:]
    @ObservationIgnored private var queryDates: [String: Date] = [:]
    @ObservationIgnored private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        NativeMessagingManifest.writeAll()
        // The App Support socket always exists (the unsandboxed bridge reaches it everywhere);
        // the group-container socket appears as soon as macOS creates that container — which
        // happens on the sandboxed Safari appex's first run, not before (spec §7.2 note).
        bind(IPCProtocol.fallbackSocketPath())
        tryBindGroupContainer()
        groupRetry = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tryBindGroupContainer() }
        }
    }

    func stop() {
        groupRetry?.invalidate()
        groupRetry = nil
        servers.forEach { $0.stop() }
        servers.removeAll()
        groupServerBound = false
    }

    private func tryBindGroupContainer() {
        guard !groupServerBound else { return }
        let preferred = IPCProtocol.socketPath()
        guard preferred != IPCProtocol.fallbackSocketPath() else { return }
        // Only bind once the container actually exists (FileManager cannot create it:
        // containermanagerd owns `TEAMID.*` creation in Group Containers).
        guard FileManager.default.fileExists(atPath: preferred.deletingLastPathComponent().path) else { return }
        bind(preferred)
    }

    private func bind(_ socketURL: URL) {
        let handler: IPCServer.Handler = { [weak self] message in
            guard let self else { return IPCResponse(id: message.id, ok: false, error: "app_closing") }
            return await self.handle(message)   // hops to the main actor
        }
        let server = IPCServer(socketURL: socketURL, handler: handler)
        do {
            try server.start()
            servers.append(server)
            if socketURL != IPCProtocol.fallbackSocketPath() { groupServerBound = true }
        } catch {
            NSLog("MacDM: could not listen on \(socketURL.path): \(error)")
        }
    }

    /// Settings summary the extension caches (spec §7.1 hello).
    private func helloOut() -> HelloOut {
        let s = model.settings.settings
        return HelloOut(appVersion: HDMCoreInfo.version,
                        captureEnabled: true,   // the popup toggle lives in the extension
                        fileTypes: s.captureExtensions,
                        exceptions: s.exceptionPatterns,
                        minimumSizeBytes: s.minimumCaptureSizeBytes,
                        panelEnabled: s.videoPanelEnabled)
    }

    private func handle(_ message: IPCMessage) async -> IPCResponse {
        pruneQueries()
        switch message.payload {
        case .none:   // ping
            return IPCResponse(id: message.id)
        case .hello(let hello):
            lastSeen[hello.browser] = Date()
            return IPCResponse(id: message.id, hello: helloOut())
        case .download(let download):
            var headers: [String: String] = [:]
            if let cookies = download.cookies, !cookies.isEmpty { headers["Cookie"] = cookies }
            if let userAgent = download.userAgent, !userAgent.isEmpty { headers["User-Agent"] = userAgent }
            let pending = PendingDownload(
                url: download.url,
                headers: headers,
                pageURL: download.pageUrl,
                referrer: download.referrer,
                suggestedName: download.filename,
                totalBytes: download.size,
                source: .browser)
            model.capture.handle(pending)
            return IPCResponse(id: message.id)
        case .downloadLinks(let links):
            model.windows.showAllLinks(links.links.map { LinkCandidate(url: $0.url, text: $0.text) },
                                       pageURL: links.pageUrl,
                                       headers: headerDict(cookies: links.cookies, userAgent: links.userAgent))
            return IPCResponse(id: message.id)
        case .mediaQuery(let query):
            return await mediaQuery(query, id: message.id)
        case .mediaDownload(let download):
            return mediaDownload(download, id: message.id)
        }
    }

    // MARK: - Media (spec §8.3 over IPC)

    private func mediaQuery(_ query: MediaQueryIn, id: String) async -> IPCResponse {
        let tools = ComponentLocator.locate()
        guard tools.ytDLP != nil else {
            return IPCResponse(id: id, ok: false, error: "yt-dlp is not installed. Install it with: brew install yt-dlp")
        }
        var headers = headerDict(cookies: query.cookies, userAgent: query.userAgent)

        // Direct media files never reach yt-dlp (spec §8.3.3): one row, downloaded by the HTTP engine.
        if query.streams.allSatisfy({ $0.kind == .file }), let file = query.streams.first, query.streams.count == 1 {
            let name = FilenameResolver.resolve(suggested: query.title, url: file.url)
            let format = MediaQueryOut.Format(id: "file", label: "Original", ext: (file.url.pathExtension).uppercased(),
                                              approxSize: nil, note: nil)
            let queryId = UUID().uuidString
            queries[queryId] = MediaQueryEntry(
                sourceURL: file.url, headers: headers,
                title: FilenameResolver.sanitize(name),
                options: [MediaFormatOption(label: "Original", selector: "", ext: file.url.pathExtension, audioOnly: false, height: nil)])
            queryDates[queryId] = Date()
            return IPCResponse(id: id, mediaQuery: MediaQueryOut(queryId: queryId, title: query.title ?? name, formats: [format]))
        }

        // Page URL first; a direct stream URL is the fallback when the page is unsupported.
        var info: YTDLPInfo?
        if let page = try? await YTDLPRunner.query(pageURL: query.pageUrl, headers: headers, tools: tools) {
            info = page
        } else if let stream = query.streams.first(where: { $0.kind == .hls || $0.kind == .dash })
                    ?? query.streams.first {
            if let referrer = query.referrer {
                headers["Referer"] = referrer.absoluteString
                headers["Origin"] = referrer.scheme! + "://" + (referrer.host() ?? "")
            }
            info = try? await YTDLPRunner.query(pageURL: stream.url, headers: headers, tools: tools)
        }
        guard let info else {
            return IPCResponse(id: id, ok: false, error: String(localized: "This page has no downloadable video."))
        }
        let video = FormatMapper.videoInfo(from: info, preferQuickTimeCompatible: model.settings.settings.preferQuickTimeCompatible)
        guard !video.options.isEmpty else {
            return IPCResponse(id: id, ok: false, error: String(localized: "No downloadable formats were found for this video."))
        }
        let queryId = UUID().uuidString
        let sourceURL = query.pageUrl
        queries[queryId] = MediaQueryEntry(sourceURL: sourceURL, headers: headers, title: video.title, options: video.options)
        queryDates[queryId] = Date()
        let formats = video.options.map {
            MediaQueryOut.Format(id: $0.label, label: $0.label, ext: $0.ext, approxSize: $0.approxSize, note: $0.note)
        }
        return IPCResponse(id: id, mediaQuery: MediaQueryOut(queryId: queryId, title: video.title, formats: formats))
    }

    private func mediaDownload(_ download: MediaDownloadIn, id: String) -> IPCResponse {
        guard let entry = queries[download.queryId] else {
            return IPCResponse(id: id, ok: false, error: "query_expired")
        }
        guard let option = entry.options.first(where: { $0.label == download.formatId }) else {
            return IPCResponse(id: id, ok: false, error: "unknown_format")
        }
        queryDates[download.queryId] = Date()   // the user picked something; keep the entry warm

        // Direct files go to the multi-connection HTTP engine (spec §8.3.3).
        if option.selector.isEmpty {
            let category = model.settings.settings.categoryResolver.category(forFileName: entry.title)
            model.manager.add(NewDownload(url: entry.sourceURL, fileName: entry.title,
                                          directory: model.settings.settings.folder(for: category),
                                          category: category, headers: entry.headers))
            return IPCResponse(id: id)
        }
        let category: DownloadCategory = option.audioOnly ? .music : .video
        let directory = model.settings.settings.folder(for: category)
        let job = MediaJob(sourceURL: entry.sourceURL, formatSelector: option.selector, sortSpec: option.sortSpec,
                           title: entry.title, audioOnly: option.audioOnly,
                           approxTotalBytes: option.approxSize, headers: entry.headers)
        model.manager.add(NewDownload(url: entry.sourceURL, fileName: entry.title, directory: directory,
                                      category: category, totalBytes: option.approxSize, media: job))
        return IPCResponse(id: id)
    }

    private func pruneQueries() {
        let cutoff = Date().addingTimeInterval(-600)   // queries live 10 minutes (spec §8.3)
        let expired = queryDates.filter { $0.value < cutoff }.map(\.key)
        expired.forEach {
            queries.removeValue(forKey: $0)
            queryDates.removeValue(forKey: $0)
        }
    }

    private func headerDict(cookies: String?, userAgent: String?) -> [String: String] {
        var headers: [String: String] = [:]
        if let cookies, !cookies.isEmpty { headers["Cookie"] = cookies }
        if let userAgent, !userAgent.isEmpty { headers["User-Agent"] = userAgent }
        return headers
    }
}

/// One row of the "all links" dialog (spec §7.5).
struct LinkCandidate: Identifiable, Hashable, Sendable {
    let id = UUID()
    var url: URL
    var text: String
}
