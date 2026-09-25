import Testing
@testable import HDMCore

@Suite struct SegmentPlannerTests {
    let mib: Int64 = 1 << 20
    var planner: SegmentPlanner { SegmentPlanner(minSegment: mib) }

    @Test func splitsEvenlyUpToConnectionCount() {
        let s = planner.initialSegments(total: 8 * mib, connections: 8)
        #expect(s.count == 8)
        #expect(s.first?.start == 0)
        #expect(s.last?.end == 8 * mib)
        #expect(zip(s, s.dropFirst()).allSatisfy { $0.end == $1.start })
    }

    @Test func respectsMinimumSegmentSize() {
        #expect(planner.initialSegments(total: mib + mib / 2, connections: 8).count == 1)
        let three = planner.initialSegments(total: 3 * mib + 5, connections: 8)
        #expect(three.count == 3)
        #expect(three.last?.end == 3 * mib + 5)
    }

    @Test func emptyFileIsOneCompleteSegment() {
        let s = planner.initialSegments(total: 0, connections: 8)
        #expect(s == [Segment(start: 0, end: 0)])
        #expect(s[0].isComplete)
    }

    @Test func prefersIdleIncompleteSegment() {
        var s = [Segment(start: 0, end: mib, received: mib),
                 Segment(start: mib, end: 2 * mib),
                 Segment(start: 2 * mib, end: 3 * mib)]
        #expect(planner.nextAssignment(segments: &s, busy: [2]) == 1)
        #expect(s.count == 3)
    }

    @Test func splitsLargestBusySegment() {
        var s = [Segment(start: 0, end: 10 * mib, received: mib),
                 Segment(start: 10 * mib, end: 12 * mib)]
        let index = planner.nextAssignment(segments: &s, busy: [0, 1])
        #expect(index == 2)
        #expect(s[0].end == mib + 9 * mib / 2)
        #expect(s[2] == Segment(start: mib + 9 * mib / 2, end: 10 * mib))
    }

    @Test func refusesToSplitSmallRemainders() {
        var s = [Segment(start: 0, end: 2 * mib, received: mib + 1)]
        #expect(planner.nextAssignment(segments: &s, busy: [0]) == nil)
        #expect(s.count == 1)
    }

    @Test func neverSplitsOpenEndedSegment() {
        var s = [Segment(start: 0, end: .max, received: 100)]
        #expect(planner.nextAssignment(segments: &s, busy: [0]) == nil)
    }
}
