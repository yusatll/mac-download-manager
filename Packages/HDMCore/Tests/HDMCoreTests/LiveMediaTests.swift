import Foundation
import Testing
@testable import HDMCore

/// End-to-end against real yt-dlp and YouTube. Skipped unless `HDM_LIVE_TESTS=1` is set, because
/// it needs the network and the installed tools. Run locally with:
///   HDM_LIVE_TESTS=1 swift test --filter LiveMediaTests
@Suite(.serialized) struct LiveMediaTests {
    static let liveEnabled = ProcessInfo.processInfo.environment["HDM_LIVE_TESTS"] == "1"
    static let zoo = URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!   // "Me at the zoo", stable since 2005
    /// Blender's uploads playlist (1583 entries): a large, stable, public playlist.
    static let blenderUploads = URL(string: "https://www.youtube.com/playlist?list=UUSMOQeBJ2RAnuFungnQOxLg")!
    /// jawed's uploads playlist: exactly one tiny video — a bounded full-playlist download.
    static let jawedUploads = URL(string: "https://www.youtube.com/playlist?list=UU4QobU6STFB0P71PMvOGN5A")!

    @Test(.enabled(if: liveEnabled)) func flatPlaylistQueryListsEntries() async throws {
        let tools = ComponentLocator.locate()
        #expect(tools.ytDLP != nil)
        let list = try await YTDLPRunner.query(pageURL: Self.blenderUploads, tools: tools, flatPlaylist: true)
        #expect(list.isPlaylist)
        #expect((list.playlistCount ?? 0) > 1000)
        #expect(!list.flatEntries.isEmpty)
        #expect(list.flatEntries.first?.url?.contains("watch") == true || list.flatEntries.first?.id != nil)
    }

    @Test(.enabled(if: liveEnabled)) func queryReturnsQualities() async throws {
        let tools = ComponentLocator.locate()
        #expect(tools.ytDLP != nil, "yt-dlp must be on this machine (brew install yt-dlp)")
        let info = try await YTDLPRunner.query(pageURL: Self.zoo, tools: tools)
        let video = FormatMapper.videoInfo(from: info)
        #expect(video.title == "Me at the zoo")
        #expect(video.duration ?? 0 > 10)
        #expect(video.options.contains { $0.audioOnly })
        #expect(!video.options.isEmpty)
        print("live formats:", video.options.map(\.label))
    }

    @Test(.enabled(if: liveEnabled)) func unsupportedURLIsRecognised() async throws {
        let tools = ComponentLocator.locate()
        #expect(tools.ytDLP != nil)
        await #expect(throws: MediaQueryError.self) {
            _ = try await YTDLPRunner.query(pageURL: URL(string: "https://example.com/")!, tools: tools)
        }
    }

    private func collect(_ engine: MediaEngine) async -> [MediaEvent] {
        var events: [MediaEvent] = []
        for await event in engine.events { events.append(event) }
        return events
    }

    @Test(.enabled(if: liveEnabled)) func audioOnlyDownloadCompletes() async throws {
        let tools = ComponentLocator.locate()
        #expect(tools.ytDLP != nil && tools.ffmpeg != nil, "yt-dlp and ffmpeg must be installed")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdm-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = MediaEngine(request: MediaRequest(
            sourceURL: Self.zoo, formatSelector: "ba/b", audioOnly: true,
            directory: dir, baseName: "Zoo Audio", approxTotalBytes: nil, tools: tools))
        let collected = Task { await collect(engine) }
        await engine.start()
        let events = await collected.value
        guard case .finished(let path, _)? = events.last else {
            Issue.record("expected .finished, got \(events)")
            return
        }
        let file = try #require(path)
        #expect(file.lastPathComponent == "Zoo Audio.m4a")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.size] as? Int64 ?? 0) > 100_000)
    }

    /// The full in-app pipeline: manager queue → media engine → 480p merge (ffmpeg) → completion,
    /// against a real YouTube video with adaptive formats.
    @MainActor @Test(.enabled(if: liveEnabled)) func videoDownloadThroughManagerCompletes() async throws {
        let tools = ComponentLocator.locate()
        #expect(tools.ytDLP != nil && tools.ffmpeg != nil, "yt-dlp and ffmpeg must be installed")
        let bunny = URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!   // Big Buck Bunny, stable Blender film
        let info = try await YTDLPRunner.query(pageURL: bunny, tools: tools)
        let video = FormatMapper.videoInfo(from: info, preferQuickTimeCompatible: true)
        let option = try #require(video.options.first { $0.height == 480 })
        #expect(option.approxSize != nil && option.approxSize! > 1_000_000)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdm-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        var s = settings.settings
        s.baseFolder = dir
        settings.settings = s
        let manager = DownloadManager(store: DownloadStore(fileURL: dir.appendingPathComponent("downloads.json")),
                                      settings: settings)
        let job = MediaJob(sourceURL: bunny, formatSelector: option.selector, sortSpec: option.sortSpec,
                           title: video.title, audioOnly: false, approxTotalBytes: option.approxSize)
        let id = manager.add(NewDownload(url: bunny, fileName: video.title, directory: dir,
                                         category: .video, media: job))
        try await waitUntil(timeout: 180) { manager.item(id)?.status == .completed }
        let item = try #require(manager.item(id))
        #expect(item.fileName.hasSuffix(".mp4"))
        #expect(item.receivedBytes > 1_000_000)
        let attributes = try FileManager.default.attributesOfItem(atPath: item.fileURL.path)
        #expect((attributes[.size] as? Int64 ?? 0) > 1_000_000)
        // No stray yt-dlp partial files remain after a clean finish.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".part") || $0.contains(".ytdl") }
        #expect(leftovers.isEmpty, "leftovers: \(leftovers)")
    }

    /// A whole playlist end to end: flat listing → one playlist job → a folder of numbered
    /// files. Uses jawed's uploads (exactly one small video) to stay bounded, and a fixed
    /// selector so the run needs only one extraction.
    @MainActor @Test(.enabled(if: liveEnabled)) func playlistDownloadThroughManagerCompletes() async throws {
        let tools = ComponentLocator.locate()
        #expect(tools.ytDLP != nil && tools.ffmpeg != nil)
        let list = try await YTDLPRunner.query(pageURL: Self.jawedUploads, tools: tools, flatPlaylist: true)
        #expect(list.isPlaylist && list.flatEntries.count == 1)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hdm-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        var s = settings.settings
        s.baseFolder = dir
        settings.settings = s
        let manager = DownloadManager(store: DownloadStore(fileURL: dir.appendingPathComponent("downloads.json")),
                                      settings: settings)
        let folderName = "Zoo List"
        let job = MediaJob(sourceURL: Self.jawedUploads,
                           formatSelector: "bv*[height<=240]+ba/b[height<=240]",
                           sortSpec: FormatMapper.quickTimeSort,
                           title: folderName, audioOnly: false, playlist: true, playlistCount: 1,
                           approxTotalBytes: 300_000)
        let id = manager.add(NewDownload(url: Self.jawedUploads, fileName: folderName, directory: dir,
                                         category: .video, totalBytes: 300_000, media: job))
        do {
            try await waitUntil(timeout: 120) { manager.item(id)?.status == .completed }
        } catch {
            Issue.record("playlist item did not complete; status: \(String(describing: manager.item(id)?.status))")
            throw error
        }
        let item = try #require(manager.item(id))
        #expect(item.fileName == folderName)
        let folder = dir.appendingPathComponent(folderName, isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { !$0.hasPrefix(".") }
        #expect(entries.count == 1)
        #expect(entries[0].hasPrefix("001 - "), "entries: \(entries)")
        #expect(entries[0].hasSuffix(".mp4"))
    }
}
