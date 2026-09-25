/// A byte range `[start, end)` of the target file and how much of it has been written.
/// `end == Int64.max` marks an open-ended range (server did not report a size).
public struct Segment: Codable, Hashable, Sendable {
    public var start: Int64
    public var end: Int64
    public var received: Int64

    public init(start: Int64, end: Int64, received: Int64 = 0) {
        self.start = start
        self.end = end
        self.received = received
    }

    public var cursor: Int64 { start + received }
    public var isOpenEnded: Bool { end == .max }
    public var remaining: Int64 { isOpenEnded ? .max : max(0, end - cursor) }
    public var isComplete: Bool { !isOpenEnded && cursor >= end }
}
