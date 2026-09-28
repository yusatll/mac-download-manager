import Foundation
import Testing
@testable import HDMCore

@Suite struct ProgressParserTests {
    @Test func parsesFullProgressLine() throws {
        let line = ProgressParser.progress("HDM|10089668|124386876|NA|15151471.2|7")
        let parsed = try #require(line)
        #expect(parsed.downloadedBytes == 10_089_668)
        #expect(parsed.totalBytes == 124_386_876)
        #expect(parsed.speed == 15_151_471.2)
        #expect(parsed.etaSeconds == 7)
    }

    @Test func handlesNAAndMissingFields() throws {
        let estimate = try #require(ProgressParser.progress("HDM|10090692|NA|204800000|8853763.8|NA"))
        #expect(estimate.totalBytes == 204_800_000)   // total_bytes NA → falls back to the estimate
        #expect(estimate.speed == 8_853_763.8)
        #expect(estimate.etaSeconds == nil)   // NA and non-positive values are dropped

        let bare = try #require(ProgressParser.progress("HDM|0|NA|NA|NA|NA"))
        #expect(bare.downloadedBytes == 0)
        #expect(bare.totalBytes == nil)
        #expect(bare.speed == nil)

        #expect(ProgressParser.progress("[download]  1.2% of 10.00MiB at ...") == nil)
        #expect(ProgressParser.progress("HDM|notanumber|NA|NA|NA|NA") == nil)
    }

    @Test func recognisesPostProcessingLines() {
        #expect(ProgressParser.isPostProcessing("[Merger] Merging formats into \"/tmp/a.mp4\""))
        #expect(ProgressParser.isPostProcessing("[ExtractAudio] Destination: /tmp/a.m4a"))
        #expect(ProgressParser.isPostProcessing("[VideoRemuxer] Remuxing video..."))
        #expect(!ProgressParser.isPostProcessing("[download] Destination: /tmp/a.f137.mp4"))
        #expect(!ProgressParser.isPostProcessing("HDM|1|2|3|4|5"))
    }

    @Test func extractsFinalPathHints() throws {
        let merged = try #require(ProgressParser.finalPathHint("[Merger] Merging formats into \"/tmp/hdm/My Video.mp4\""))
        #expect(merged.path == "/tmp/hdm/My Video.mp4")

        let audio = try #require(ProgressParser.finalPathHint("[ExtractAudio] Destination: /tmp/hdm/My Video.m4a"))
        #expect(audio.path == "/tmp/hdm/My Video.m4a")

        let already = try #require(ProgressParser.finalPathHint("[download] /tmp/hdm/My Video.mp4 has already been downloaded"))
        #expect(already.path == "/tmp/hdm/My Video.mp4")

        #expect(ProgressParser.finalPathHint("HDM|1|2|3|4|5") == nil)
        #expect(ProgressParser.finalPathHint("[info] something else") == nil)
    }
}

@Suite struct MediaPlanTests {
    private func makeRequest(audioOnly: Bool = false, sortSpec: String? = FormatMapper.quickTimeSort,
                             limit: Int64 = 0, headers: [String: String] = [:]) -> MediaRequest {
        MediaRequest(sourceURL: URL(string: "https://youtu.be/xyz")!,
                     formatSelector: audioOnly ? "ba/b" : "bv*[height<=720]+ba/b[height<=720]",
                     sortSpec: sortSpec, audioOnly: audioOnly,
                     directory: URL(fileURLWithPath: "/tmp/hdm"), baseName: "My Video",
                     approxTotalBytes: 1000, headers: headers,
                     tools: ComponentPaths(ytDLP: URL(fileURLWithPath: "/opt/bin/yt-dlp"),
                                           ffmpeg: URL(fileURLWithPath: "/opt/bin/ffmpeg"),
                                           deno: URL(fileURLWithPath: "/opt/bin/deno")),
                     concurrentFragments: 8, speedLimitBytesPerSecond: limit)
    }

    private func arg(_ args: [String], after flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    @Test func videoArguments() {
        let args = MediaPlan.arguments(for: makeRequest())
        #expect(arg(args, after: "-f") == "bv*[height<=720]+ba/b[height<=720]")
        #expect(arg(args, after: "-S") == FormatMapper.quickTimeSort)
        #expect(arg(args, after: "--merge-output-format") == "mp4")
        #expect(args.contains("-N"))
        #expect(arg(args, after: "-o") == "/tmp/hdm/My Video.%(ext)s")
        #expect(arg(args, after: "--ffmpeg-location") == "/opt/bin")
        #expect(arg(args, after: "--js-runtimes") == "deno:/opt/bin")
        #expect(arg(args, after: "--progress-template") == MediaPlan.progressTemplate)
        #expect(args.contains("--no-playlist") && args.contains("--continue") && args.contains("--newline"))
        #expect(args.last == "https://youtu.be/xyz")
        // progress template fields in yt-dlp order: downloaded, total, estimate, speed, eta
        #expect(MediaPlan.progressTemplate.contains("%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s"))
    }

    @Test func audioArguments() {
        let args = MediaPlan.arguments(for: makeRequest(audioOnly: true, sortSpec: nil))
        #expect(arg(args, after: "-x") == "--audio-format")
        #expect(arg(args, after: "--audio-format") == "m4a")
        #expect(!args.contains("--merge-output-format"))
        #expect(args.firstIndex(of: "-S") == nil)
    }

    @Test func rateLimitAndHeaders() {
        var request = makeRequest(limit: 2 << 20)
        request.headers = ["Referer": "https://example.com/watch", "Origin": "https://example.com"]
        let args = MediaPlan.arguments(for: request)
        #expect(arg(args, after: "-r") == "2M")
        // headers sorted for deterministic arguments
        let refererIndex = args.firstIndex(of: "--add-header")!
        #expect(args[refererIndex + 1] == "Origin: https://example.com")
        #expect(args[refererIndex + 3] == "Referer: https://example.com/watch")
    }

    @Test func playlistArguments() {
        var request = makeRequest()
        request.playlist = true
        request.directory = URL(fileURLWithPath: "/tmp/hdm/My List")
        request.baseName = "%(playlist_index)03d - %(title).190B"
        let args = MediaPlan.arguments(for: request)
        #expect(args.contains("--yes-playlist"))
        #expect(!args.contains("--no-playlist"))
        #expect(arg(args, after: "-o") == "/tmp/hdm/My List/%(playlist_index)03d - %(title).190B.%(ext)s")

        let single = MediaPlan.arguments(for: makeRequest())
        #expect(single.contains("--no-playlist"))
        #expect(!single.contains("--yes-playlist"))
    }

    @Test func missingToolsOmitTheirFlags() {
        var request = makeRequest()
        request.tools = ComponentPaths(ytDLP: URL(fileURLWithPath: "/opt/bin/yt-dlp"))
        let args = MediaPlan.arguments(for: request)
        #expect(args.firstIndex(of: "--ffmpeg-location") == nil)
        #expect(args.firstIndex(of: "--js-runtimes") == nil)
    }

    @Test func rateLimitFormatting() {
        #expect(MediaPlan.rateLimit(0) == "0")
        #expect(MediaPlan.rateLimit(999) == "999")
        #expect(MediaPlan.rateLimit(1024) == "1K")
        #expect(MediaPlan.rateLimit(1_500_000) == "1500000")   // not a whole MiB
        #expect(MediaPlan.rateLimit(2 << 20) == "2M")
        #expect(MediaPlan.rateLimit(4 << 30) == "4G")
    }
}
