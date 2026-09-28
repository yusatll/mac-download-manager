import Foundation
import Testing
@testable import HDMCore

/// FormatMapper tests against realistic yt-dlp JSON shapes (YouTube-style adaptive + muxed formats,
/// direct single files, playlists wrapping entries).
@Suite struct FormatMapperTests {
    @Test func mapsHeightsToQualityRows() throws {
        let info = try decode(fixture: youTubeFormats)
        let options = FormatMapper.options(from: info, preferQuickTimeCompatible: true)
        let labels = options.map(\.label)
        #expect(labels == ["1080p", "720p", "480p", "360p", "Audio only"])

        let h1080 = options[0]
        #expect(h1080.selector == "bv*[height<=1080]+ba/b[height<=1080]")
        #expect(h1080.sortSpec == FormatMapper.quickTimeSort)
        #expect(h1080.ext == "MP4")
        // best 1080p video (h264, 124386876) + best audio (m4a, 10271496)
        #expect(h1080.approxSize == 134658372)
        #expect(h1080.note == nil)   // H.264 available at that height

        let h720 = options[1]
        #expect(h720.approxSize == 62436056)
        #expect(h720.note == "VP9 — VLC/IINA recommended")   // only VP9 at 720p

        let audio = options.last!
        #expect(audio.audioOnly)
        #expect(audio.selector == "ba/b")
        #expect(audio.sortSpec == nil)
        #expect(audio.approxSize == 10271496)   // m4a 140 preferred over opus 251 by rank
    }

    @Test func withoutQuickTimePreferenceNoSortSpec() throws {
        let options = FormatMapper.options(from: try decode(fixture: youTubeFormats), preferQuickTimeCompatible: false)
        #expect(options.allSatisfy { $0.sortSpec == nil || $0.audioOnly })
        #expect(options.first?.sortSpec == nil)
    }

    @Test func muxedOnlySourceYieldsFallbackRow() throws {
        let options = FormatMapper.options(from: try decode(fixture: muxedOnly), preferQuickTimeCompatible: true)
        #expect(options.count == 2)   // the 360p muxed row + audio-only
        #expect(options[0].label == "360p")
        #expect(options[0].approxSize == 28526904)
    }

    @Test func directFileYieldsRowsFromTopLevelFormat() throws {
        let info = try decode(fixture: directFile)
        let video = FormatMapper.videoInfo(from: info)
        #expect(video.title == "clip")
        #expect(video.options.count == 2)   // 720p (the file itself) + audio-only extraction
        #expect(video.options[0].label == "720p")
        #expect(video.options[0].approxSize == 512000)
    }

    @Test func playlistJSONUnwrapsFirstEntry() throws {
        let info = try decode(fixture: playlist)
        #expect(info.title == "First Video")
        #expect(info.allFormats.count == 3)
        let video = FormatMapper.videoInfo(from: info)
        #expect(video.options.first?.label == "720p")
    }

    @Test func skipsStoryboardsAndDrcAudio() throws {
        let options = FormatMapper.options(from: try decode(fixture: youTubeFormats), preferQuickTimeCompatible: true)
        // storyboard formats (mhtml, vcodec none + acodec none) never appear as heights
        #expect(!options.contains { $0.label == "180p" })
        // audio size comes from the plain m4a, not the -drc variant
        let audio = options.last!
        #expect(audio.approxSize == 10271496)
    }

    @Test func decodesRealYouTubeJSON() throws {
        // A trimmed copy of an actual `yt-dlp -J` response.
        let url = Bundle.module.url(forResource: "ytdlp-youtube", withExtension: "json")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ytdlp-youtube.json")
        let info = try decode(fixture: try String(contentsOf: url, encoding: .utf8))
        let video = FormatMapper.videoInfo(from: info)
        #expect(video.title == "Big Buck Bunny 60fps 4K - Official Blender Foundation Short Film")
        #expect(!video.isLive)
        #expect(video.options.contains { $0.label == "1080p" })
        #expect(video.options.contains { $0.label == "Audio only" })
        #expect(video.options.first!.height! >= video.options.dropLast().last!.height!)
    }

    private func decode(fixture: String) throws -> YTDLPInfo {
        try JSONDecoder().decode(YTDLPInfo.self, from: Data(fixture.utf8))
    }

    private var youTubeFormats: String {
        """
        {"title":"Test Video","duration":635,"uploader":"Blender",
         "formats":[
          {"format_id":"sb0","ext":"mhtml","vcodec":"none","acodec":"none","height":180},
          {"format_id":"140","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","filesize":10271496,"tbr":129.7,"format_note":"medium"},
          {"format_id":"140-drc","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","filesize":9999999,"tbr":129.0,"format_note":"medium, DRC"},
          {"format_id":"251","ext":"webm","vcodec":"none","acodec":"opus","filesize":10202210,"tbr":130.5},
          {"format_id":"137","ext":"mp4","vcodec":"avc1.640028","acodec":"none","height":1080,"filesize":124386876,"tbr":1566.4},
          {"format_id":"248","ext":"webm","vcodec":"vp09.00.40.08","acodec":"none","height":1080,"filesize":119000000,"tbr":1500.0},
          {"format_id":"247","ext":"webm","vcodec":"vp9","acodec":"none","height":720,"filesize":52164560,"tbr":655.9},
          {"format_id":"135","ext":"mp4","vcodec":"avc1.4d401f","acodec":"none","height":480,"filesize":22453000,"tbr":282.3},
          {"format_id":"18","ext":"mp4","vcodec":"avc1.42001E","acodec":"mp4a.40.2","height":360,"filesize":28526904,"tbr":358.6}
         ]}
        """
    }

    private var muxedOnly: String {
        """
        {"title":"Old extraction","duration":19,
         "formats":[{"format_id":"18","ext":"mp4","vcodec":"avc1.42001E","acodec":"mp4a.40.2","height":360,"filesize":28526904,"tbr":266.5}]}
        """
    }

    private var directFile: String {
        """
        {"title":"clip","id":"0","url":"https://cdn.example.com/clip.mp4","ext":"mp4",
         "format_id":"mp4-1","vcodec":"avc1.64001f","acodec":"mp4a.40.2","height":720,"width":1280,"filesize":512000}
        """
    }

    private var playlist: String {
        """
        {"title":"My Playlist","entries":[
          {"title":"First Video","duration":61,
           "formats":[
            {"format_id":"140","ext":"m4a","vcodec":"none","acodec":"mp4a.40.2","filesize":1000},
            {"format_id":"247","ext":"webm","vcodec":"vp9","acodec":"none","height":720,"filesize":2000},
            {"format_id":"135","ext":"mp4","vcodec":"avc1.4d401f","acodec":"none","height":480,"filesize":1500}]}]}
        """
    }
}
