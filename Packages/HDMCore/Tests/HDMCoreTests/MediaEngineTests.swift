import Foundation
import Testing
@testable import HDMCore

/// MediaEngine driven by a stub `yt-dlp` shell script, so the process plumbing (pipes, line
/// parsing, SIGINT pause, exit handling) is covered without touching the network.
@Suite(.serialized) struct MediaEngineTests {
    /// Writes a stub executable emulating yt-dlp. Modes: `ok` (two formats, merge, final print),
    /// `fail` (stderr error, exit 1), `hang` (sleeps, exits on SIGINT via trap).
    private func makeStub(mode: String) throws -> URL {
        let dir = tempDirectory()
        let stub = dir.appendingPathComponent("yt-dlp")
        let script = """
        #!/bin/sh
        mode="\(mode)"
        out=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -o) out="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        base="${out%\\%(ext)s}"
        case "$mode" in
          ok)
            echo "HDM|500|1000|NA|1000.0|0"
            echo "[download] Destination: ${base}f137.mp4"
            echo "HDM|1000|1000|NA|1000.0|0"
            echo "[download] Destination: ${base}f140.m4a"
            echo "HDM|200|400|NA|1000.0|1"
            echo "HDM|400|400|NA|1000.0|0"
            echo "[Merger] Merging formats into \\"${base}mp4\\""
            echo "stub media content" > "${base}mp4"
            echo "${base}mp4"
            exit 0
            ;;
          fail)
            echo "ERROR: [stub] Video unavailable" >&2
            exit 1
            ;;
          hang)
            trap 'exit 130' INT TERM
            sleep 30
            exit 0
            ;;
        esac
        exit 99
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    private func makeRequest(stub: URL, directory: URL, approxTotal: Int64? = 1400, audioOnly: Bool = false) -> MediaRequest {
        MediaRequest(sourceURL: URL(string: "https://youtu.be/xyz")!,
                     formatSelector: audioOnly ? "ba/b" : "bv*[height<=720]+ba/b[height<=720]",
                     audioOnly: audioOnly, directory: directory, baseName: "My Video",
                     approxTotalBytes: approxTotal,
                     tools: ComponentPaths(ytDLP: stub))
    }

    private func collect(_ engine: MediaEngine) async -> [MediaEvent] {
        var events: [MediaEvent] = []
        for await event in engine.events { events.append(event) }
        return events
    }

    @Test func successReportsMonotonicProgressMergeAndFinalPath() async throws {
        let stub = try makeStub(mode: "ok")
        let dir = tempDirectory()
        let engine = MediaEngine(request: makeRequest(stub: stub, directory: dir))
        let collected = Task { await collect(engine) }
        await engine.start()
        let events = await collected.value

        let progress = events.compactMap { event -> Int64? in
            if case .progress(let received, _) = event { return received } else { return nil }
        }
        // The second format restarts at 200 after 1000; overall progress must never go backwards.
        #expect(progress == [500, 1000, 1200, 1400])
        let totals = events.compactMap { event -> Int64? in
            if case .progress(_, let total) = event { return total } else { return nil }
        }
        #expect(totals.allSatisfy { $0 == 1400 })   // from approxTotalBytes, not the per-format total
        #expect(events.contains(.postProcessing))
        guard case .finished(let path, let total)? = events.last else {
            Issue.record("expected .finished, got \(events)")
            return
        }
        #expect(total == 1400)
        let final = try #require(path)
        #expect(final.lastPathComponent == "My Video.mp4")
        #expect(try String(contentsOf: final, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "stub media content")
    }

    @Test func failureSurfacesCleanedStderr() async throws {
        let stub = try makeStub(mode: "fail")
        let engine = MediaEngine(request: makeRequest(stub: stub, directory: tempDirectory()))
        let collected = Task { await collect(engine) }
        await engine.start()
        let events = await collected.value
        guard case .failed(.media(let message))? = events.last else {
            Issue.record("expected .failed(.media), got \(events)")
            return
        }
        #expect(message == "[stub] Video unavailable")   // "ERROR: " prefix stripped
    }

    @Test func pauseInterruptsWithoutFailure() async throws {
        let stub = try makeStub(mode: "hang")
        let engine = MediaEngine(request: makeRequest(stub: stub, directory: tempDirectory()))
        let collected = Task { await collect(engine) }
        await engine.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        await engine.pause()   // returns once the process is dead and the stream finished
        let events = await collected.value
        #expect(events.isEmpty)   // a manager-initiated pause is not a failure
    }

    @Test func missingToolFailsImmediately() async throws {
        let engine = MediaEngine(request: MediaRequest(sourceURL: URL(string: "https://youtu.be/x")!,
                                                       formatSelector: "ba/b", audioOnly: true,
                                                       directory: tempDirectory(), baseName: "x",
                                                       tools: ComponentPaths()))
        let collected = Task { await collect(engine) }
        await engine.start()
        let events = await collected.value
        guard case .failed(.media(let message))? = events.last else {
            Issue.record("expected .failed(.media), got \(events)")
            return
        }
        #expect(message.contains("yt-dlp"))
    }
}

/// DownloadManager driving media items through the stub (queue → progress → completion, pause,
/// persistence across a relaunch).
@MainActor @Suite(.serialized) struct DownloadManagerMediaTests {
    private func makeManager(dir: URL, stub: URL) -> DownloadManager {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        var s = settings.settings
        s.baseFolder = dir
        settings.settings = s
        return DownloadManager(store: DownloadStore(fileURL: dir.appendingPathComponent("downloads.json")),
                               settings: settings, minSegment: 64 * 1024, backoff: fastBackoff,
                               mediaTools: { ComponentPaths(ytDLP: stub) })
    }

    private func writeStub(mode: String) throws -> URL {
        // A minimal second copy of the engine stub; kept local so this suite is standalone.
        let dir = tempDirectory()
        let stub = dir.appendingPathComponent("yt-dlp")
        let script = """
        #!/bin/sh
        mode="\(mode)"
        out=""
        while [ $# -gt 0 ]; do
          case "$1" in
            -o) out="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        base="${out%\\%(ext)s}"
        case "$mode" in
          ok)
            echo "HDM|1000|1000|NA|1000.0|0"
            echo "[Merger] Merging formats into \\"${base}mp4\\""
            echo "stub media content" > "${base}mp4"
            echo "${base}mp4"
            exit 0
            ;;
          hang)
            trap 'exit 130' INT TERM
            sleep 30
            ;;
        esac
        exit 99
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    @Test func mediaItemDownloadsMergesAndCompletes() async throws {
        let dir = tempDirectory()
        let manager = makeManager(dir: dir, stub: try writeStub(mode: "ok"))
        let job = MediaJob(sourceURL: URL(string: "https://youtu.be/xyz")!,
                           formatSelector: "bv*[height<=1080]+ba/b[height<=1080]",
                           sortSpec: FormatMapper.quickTimeSort, title: "My Video", audioOnly: false,
                           approxTotalBytes: 1000)
        let id = manager.add(NewDownload(url: job.sourceURL, fileName: "My Video", directory: dir,
                                         category: .video, media: job))
        try await waitUntil { manager.item(id)?.status == .completed }
        let item = try #require(manager.item(id))
        #expect(item.kind == .media)
        #expect(item.fileName == "My Video.mp4")
        #expect(item.receivedBytes == 1000)
        #expect(try String(contentsOf: item.fileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "stub media content")
        let quarantine = try item.fileURL.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(quarantine != nil)
    }

    @Test func sameTitleMediaItemsGetUniqueBaseNames() {
        let dir = tempDirectory()
        let manager = makeManager(dir: dir, stub: dir.appendingPathComponent("nope"))
        let job = MediaJob(sourceURL: URL(string: "https://youtu.be/a")!, formatSelector: "ba/b",
                           title: "Same Song", audioOnly: true)
        let a = manager.add(NewDownload(url: job.sourceURL, fileName: "Same Song", directory: dir, category: .music, media: job))
        let b = manager.add(NewDownload(url: job.sourceURL, fileName: "Same Song", directory: dir, category: .music, media: job))
        #expect(manager.item(a)?.fileName == "Same Song.m4a")
        #expect(manager.item(b)?.fileName == "Same Song (2).m4a")
    }

    @Test func pauseAndResumeMediaRunThroughStub() async throws {
        let dir = tempDirectory()
        let stub = try writeStub(mode: "hang")
        let manager = makeManager(dir: dir, stub: stub)
        let job = MediaJob(sourceURL: URL(string: "https://youtu.be/xyz")!, formatSelector: "ba/b",
                           title: "Song", audioOnly: false, approxTotalBytes: 500)
        let id = manager.add(NewDownload(url: job.sourceURL, fileName: "Song", directory: dir, category: .video, media: job))
        try await waitUntil { manager.item(id)?.status == .connecting || manager.item(id)?.status == .downloading }
        await manager.pause([id])
        #expect(manager.item(id)?.status == .paused)

        // Resume swaps in a completing stub through the injected tools provider.
        let okStub = try writeStub(mode: "ok")
        let swapped = makeManager(dir: dir, stub: okStub)   // fresh manager = relaunch with new tools
        let restored = try #require(swapped.item(id))
        #expect(restored.status == .paused)
        #expect(restored.media == job)
        swapped.resume([id])
        try await waitUntil { swapped.item(id)?.status == .completed }
        #expect(swapped.item(id)?.fileName == "Song.mp4")
    }

    @Test func missingToolsFailTheItemWithAGuide() async throws {
        let dir = tempDirectory()
        let manager = makeManager(dir: dir, stub: dir.appendingPathComponent("missing"))
        let job = MediaJob(sourceURL: URL(string: "https://youtu.be/xyz")!, formatSelector: "ba/b",
                           title: "Song", audioOnly: false)
        let id = manager.add(NewDownload(url: job.sourceURL, fileName: "Song", directory: dir, category: .video, media: job))
        try await waitUntil { manager.item(id)?.status.isRunning == false }
        guard case .failed(.media(let message))? = manager.item(id)?.status else {
            Issue.record("expected media failure, got \(String(describing: manager.item(id)?.status))")
            return
        }
        #expect(message.contains("yt-dlp") && message.contains("brew install"))
    }

    @Test func removeCancelsTheEngineAndCleansPartials() async throws {
        let dir = tempDirectory()
        let manager = makeManager(dir: dir, stub: try writeStub(mode: "hang"))
        let job = MediaJob(sourceURL: URL(string: "https://youtu.be/xyz")!, formatSelector: "ba/b",
                           title: "Gone", audioOnly: false)
        let id = manager.add(NewDownload(url: job.sourceURL, fileName: "Gone", directory: dir, category: .video, media: job))
        try await waitUntil { manager.item(id)?.status.isRunning == true }
        // Pretend yt-dlp left a partial file behind.
        try Data("x".utf8).write(to: dir.appendingPathComponent("Gone.f137.mp4.part"))
        manager.remove([id], deleteFiles: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(manager.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Gone.f137.mp4.part").path))
    }
}
