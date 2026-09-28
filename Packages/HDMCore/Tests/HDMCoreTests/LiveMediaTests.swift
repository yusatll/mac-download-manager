import Foundation
import Testing
@testable import HDMCore

/// End-to-end against real yt-dlp and YouTube. Skipped unless `HDM_LIVE_TESTS=1` is set, because
/// it needs the network and the installed tools. Run locally with:
///   HDM_LIVE_TESTS=1 swift test --filter LiveMediaTests
@Suite(.serialized) struct LiveMediaTests {
    static let liveEnabled = ProcessInfo.processInfo.environment["HDM_LIVE_TESTS"] == "1"
    static let zoo = URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw")!   // "Me at the zoo", stable since 2005

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

    /// The full in-app pipeline: manager queue → media engine → 720p merge (ffmpeg) → completion,
    /// against a real YouTube video with adaptive formats.
    @MainActor @Test(.enabled(if: liveEnabled)) func videoDownloadThroughManagerCompletes() async throws {
        let tools = ComponentLocator.locate()
        #expect(tools.ytDLP != nil && tools.ffmpeg != nil, "yt-dlp and ffmpeg must be installed")
        let bunny = URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!   // Big Buck Bunny, stable Blender film
        let info = try await YTDLPRunner.query(pageURL: bunny, tools: tools)
        let video = FormatMapper.videoInfo(from: info, preferQuickTimeCompatible: true)
        let option = try #require(video.options.first { $0.height == 720 })
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
}
