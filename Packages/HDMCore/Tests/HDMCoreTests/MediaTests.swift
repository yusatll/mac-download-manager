import Foundation
import Testing
@testable import HDMCore

@Suite struct MediaModelTests {
    @Test func mediaJobRoundTrip() throws {
        let job = MediaJob(sourceURL: URL(string: "https://youtube.com/watch?v=x")!,
                           formatSelector: "bv*[height<=720]+ba/b[height<=720]",
                           sortSpec: FormatMapper.quickTimeSort, title: "Big Buck Bunny", audioOnly: false,
                           approxTotalBytes: 12345, headers: ["Referer": "https://youtube.com"])
        let back = try JSONDecoder().decode(MediaJob.self, from: JSONEncoder().encode(job))
        #expect(back == job)
    }

    @Test func downloadItemDecodesWithoutMediaField() throws {
        // downloads.json written before the media feature has no "media" key.
        var item = DownloadItem(url: URL(string: "https://e.com/a.zip")!, fileName: "a.zip",
                                saveDirectory: URL(fileURLWithPath: "/tmp/d"), category: .compressed)
        item.status = .paused
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        json["media"] = nil   // strip the field an older writer would not have written
        let legacy = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: legacy)
        #expect(decoded.media == nil)
        #expect(decoded.kind == .http)
        #expect(decoded.fileName == "a.zip")
    }

    @Test func downloadItemMediaRoundTrip() throws {
        let job = MediaJob(sourceURL: URL(string: "https://youtu.be/x")!, formatSelector: "ba/b",
                           title: "Song", audioOnly: true)
        let item = DownloadItem(url: job.sourceURL, fileName: "Song.m4a",
                                saveDirectory: URL(fileURLWithPath: "/tmp/d"), category: .music, media: job)
        #expect(item.kind == .media)
        let back = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(item))
        #expect(back.media == job)
        #expect(back.kind == .media)
    }

    @Test func failureReasonMediaCodable() throws {
        let reason = FailureReason.media("Video unavailable")
        let back = try JSONDecoder().decode(FailureReason.self, from: JSONEncoder().encode(reason))
        #expect(back == reason)
    }

    @Test func mediaJobDecodesOldRevisionsWithDefaults() throws {
        // Written before playlists existed: no playlist keys.
        let legacy = #"{"sourceURL":"https://youtu.be/x","formatSelector":"ba/b","title":"Song","audioOnly":true,"headers":{}}"#
        let job = try JSONDecoder().decode(MediaJob.self, from: Data(legacy.utf8))
        #expect(!job.playlist)
        #expect(job.playlistCount == nil)
        #expect(job.audioOnly)
    }

    @Test func mediaJobPlaylistRoundTrip() throws {
        let job = MediaJob(sourceURL: URL(string: "https://youtube.com/playlist?list=X")!,
                           formatSelector: "bv*[height<=720]+ba/b[height<=720]", title: "My List",
                           audioOnly: false, playlist: true, playlistCount: 12,
                           approxTotalBytes: 1_200_000_000)
        let back = try JSONDecoder().decode(MediaJob.self, from: JSONEncoder().encode(job))
        #expect(back == job)
        #expect(back.playlist && back.playlistCount == 12)
    }

    @Test func flatPlaylistJSONDecodesEntries() throws {
        let json = """
        {"_type":"playlist","title":"Uploads from Blender","playlist_count":1583,
         "entries":[
          {"id":"a1","title":"First","duration":61,"url":"https://www.youtube.com/watch?v=a1"},
          {"id":"b2","title":"Second","duration":122}
         ]}
        """
        let info = try JSONDecoder().decode(YTDLPInfo.self, from: Data(json.utf8))
        #expect(info.isPlaylist)
        #expect(info.playlistTitle == "Uploads from Blender")
        #expect(info.playlistCount == 1583)
        #expect(info.flatEntries.count == 2)
        #expect(info.flatEntries[0].url == "https://www.youtube.com/watch?v=a1")
        #expect(info.duration == 183)   // flat entries' durations are summed
    }

    @Test func mediaSitesHeuristic() {
        func url(_ s: String) -> URL { URL(string: s)! }
        #expect(MediaSites.isKnownVideoSite(url("https://www.youtube.com/watch?v=x")))
        #expect(MediaSites.isKnownVideoSite(url("https://m.youtube.com/watch?v=x")))
        #expect(MediaSites.isKnownVideoSite(url("https://music.youtube.com/watch?v=x")))
        #expect(MediaSites.isKnownVideoSite(url("https://youtu.be/x")))
        #expect(MediaSites.isKnownVideoSite(url("https://player.vimeo.com/video/1")))
        #expect(MediaSites.isKnownVideoSite(url("https://www.tiktok.com/@u/video/1")))
        #expect(!MediaSites.isKnownVideoSite(url("https://example.com/watch")))
        #expect(!MediaSites.isKnownVideoSite(url("https://notyoutube.com/watch?v=x")))
        #expect(!MediaSites.isKnownVideoSite(url("https://youtube.com.evil.io/watch")))
    }
}
