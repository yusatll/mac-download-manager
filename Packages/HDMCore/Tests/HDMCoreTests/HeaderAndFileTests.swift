import Foundation
import Testing
@testable import HDMCore

@Suite struct HeaderAndFileTests {
    func temp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("hdm-\(UUID().uuidString).hdmpart") }

    @Test func parsesContentRange() {
        #expect(ContentRange(header: "bytes 0-99/1000") == ContentRange(start: 0, end: 99, total: 1000))
        #expect(ContentRange(header: "bytes 5-9/*")?.total == nil)
        #expect(ContentRange(header: "bytes 9-5/10") == nil)
        #expect(ContentRange(header: "items 0-1/2") == nil)
        #expect(ContentRange(header: nil) == nil)
    }

    @Test func probeResultReadsHeaders() {
        let url = URL(string: "https://e.com/f")!
        let partial = HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Range": "bytes 0-9/5000", "ETag": "\"abc\"", "Last-Modified": "Mon, 01 Jan 2024 00:00:00 GMT",
            "Content-Disposition": "attachment; filename=\"x.zip\"", "Content-Type": "application/zip"])!
        let p = ProbeResult(response: partial)
        #expect(p.totalBytes == 5000 && p.resumable && p.etag == "\"abc\"" && p.ifRangeValidator == "\"abc\"")
        #expect(p.contentDisposition == "attachment; filename=\"x.zip\"" && p.mimeType == "application/zip")

        let full = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Length": "77", "ETag": "W/\"weak\"", "Last-Modified": "Mon, 01 Jan 2024 00:00:00 GMT"])!
        let f = ProbeResult(response: full)
        #expect(f.totalBytes == 77 && !f.resumable && f.etag == nil)
        #expect(f.ifRangeValidator == "Mon, 01 Jan 2024 00:00:00 GMT")
    }

    @Test func partFileWritesAtOffsetsAndOnlyGrows() throws {
        let url = temp()
        let file = try PartFile(url: url)
        try file.resize(atLeast: 10)
        try file.write(Data([1, 2, 3]), at: 7)
        try file.write(Data([9]), at: 0)
        try file.resize(atLeast: 4)
        file.close()
        #expect(try Data(contentsOf: url) == Data([9, 0, 0, 0, 0, 0, 0, 1, 2, 3]))
        #expect(throws: PartFileError.closed) { try file.write(Data([1]), at: 0) }
    }

    @Test func segmentTableClampsAtSegmentEnd() throws {
        let url = temp()
        let table = SegmentTable(segments: [Segment(start: 0, end: 4), Segment(start: 4, end: 8)],
                                 planner: SegmentPlanner(minSegment: 1), file: try PartFile(url: url))
        #expect(try table.write(Data([1, 1]), segment: 0) == .more)
        #expect(try table.write(Data([2, 2, 2, 2]), segment: 0) == .segmentDone)
        #expect(table.segment(0).received == 4)
        #expect(try table.write(Data([5, 6, 7, 8]), segment: 1) == .segmentDone)
        #expect(table.allComplete && table.receivedBytes == 8)
        table.closeFile()
        #expect(try Data(contentsOf: url) == Data([1, 1, 2, 2, 5, 6, 7, 8]))
    }

    @Test func segmentTableClaimsAndSplits() throws {
        let table = SegmentTable(segments: [Segment(start: 0, end: 100)], planner: SegmentPlanner(minSegment: 10),
                                 file: try PartFile(url: temp()))
        #expect(table.claimNext() == 0)
        #expect(table.claimNext() == 1)
        #expect(table.snapshot() == [Segment(start: 0, end: 50), Segment(start: 50, end: 100)])
        table.release(1)
        #expect(table.claimNext() == 1)
    }

    @Test func openEndedSegmentCanBeClosed() throws {
        let table = SegmentTable(segments: [Segment(start: 0, end: .max)], planner: SegmentPlanner(),
                                 file: try PartFile(url: temp()))
        _ = try table.write(Data(count: 5), segment: 0)
        #expect(!table.allComplete)
        table.closeOpenEnded(0)
        #expect(table.allComplete && table.segment(0) == Segment(start: 0, end: 5, received: 5))
    }
}
