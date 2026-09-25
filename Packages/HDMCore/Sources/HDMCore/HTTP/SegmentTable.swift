import Foundation

/// The live segment list of one download. Writes and split decisions happen under one lock,
/// so a split can never hand out bytes that another connection is writing.
public final class SegmentTable: @unchecked Sendable {
    public enum WriteOutcome: Equatable, Sendable { case more, segmentDone }

    private let lock = NSLock()
    private var segments: [Segment]
    private var busy: Set<Int> = []
    private let planner: SegmentPlanner
    private let file: PartFile

    public init(segments: [Segment], planner: SegmentPlanner, file: PartFile) {
        self.segments = segments
        self.planner = planner
        self.file = file
    }

    /// Writes as much of `data` as fits in the segment; bytes past its end are dropped.
    public func write(_ data: Data, segment index: Int) throws -> WriteOutcome {
        try lock.withLock {
            var segment = segments[index]
            if segment.isComplete { return .segmentDone }
            let allowed = segment.isOpenEnded ? data.count : Int(min(Int64(data.count), segment.end - segment.cursor))
            if allowed > 0 { try file.write(data.prefix(allowed), at: segment.cursor) }
            segment.received += Int64(allowed)
            segments[index] = segment
            return segment.isComplete ? .segmentDone : .more
        }
    }

    public func claimNext() -> Int? {
        lock.withLock {
            let index = planner.nextAssignment(segments: &segments, busy: busy)
            if let index { busy.insert(index) }
            return index
        }
    }

    public func claim(_ index: Int) { lock.withLock { _ = busy.insert(index) } }
    public func release(_ index: Int) { lock.withLock { _ = busy.remove(index) } }
    public func replace(with new: [Segment]) { lock.withLock { segments = new } }
    public func segment(_ index: Int) -> Segment { lock.withLock { segments[index] } }
    public func closeOpenEnded(_ index: Int) { lock.withLock { segments[index].end = segments[index].cursor } }
    public func snapshot() -> [Segment] { lock.withLock { segments } }
    public var receivedBytes: Int64 { lock.withLock { segments.reduce(0) { $0 + $1.received } } }
    public var allComplete: Bool { lock.withLock { segments.allSatisfy(\.isComplete) } }
    public func resize(atLeast size: Int64) throws { try file.resize(atLeast: size) }
    public func closeFile() { lock.withLock { file.close() } }
}
