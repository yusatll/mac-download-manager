/// Pure segmentation decisions (spec §5.3). No I/O, so every rule is unit-testable.
public struct SegmentPlanner: Sendable {
    public let minSegment: Int64

    public init(minSegment: Int64 = 1 << 20) {
        self.minSegment = max(1, minSegment)
    }

    public func initialSegments(total: Int64, connections: Int) -> [Segment] {
        guard total > 0 else { return [Segment(start: 0, end: 0)] }
        let count = max(1, min(Int64(max(1, connections)), total / minSegment))
        let size = total / count
        return (0..<count).map { i in
            Segment(start: i * size, end: i == count - 1 ? total : (i + 1) * size)
        }
    }

    /// Picks work for a free connection: an unclaimed incomplete segment first, otherwise the
    /// busy segment with the most bytes left is cut in half and the upper half is appended.
    public func nextAssignment(segments: inout [Segment], busy: Set<Int>) -> Int? {
        if let idle = segments.indices.first(where: { !segments[$0].isComplete && !busy.contains($0) }) {
            return idle
        }
        let candidates = busy.filter { $0 < segments.count && !segments[$0].isComplete && !segments[$0].isOpenEnded }
        guard let victim = candidates.max(by: { segments[$0].remaining < segments[$1].remaining }) else { return nil }
        let segment = segments[victim]
        guard segment.remaining >= 2 * minSegment else { return nil }
        let middle = segment.cursor + segment.remaining / 2
        segments[victim].end = middle
        segments.append(Segment(start: middle, end: segment.end))
        return segments.count - 1
    }
}
