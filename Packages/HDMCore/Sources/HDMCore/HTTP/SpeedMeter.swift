import Foundation

public struct SpeedMeter: Sendable {
    private struct Sample: Sendable { var time: TimeInterval; var bytes: Int64 }
    private var samples: [Sample] = []
    public let window: TimeInterval

    public init(window: TimeInterval = 3) { self.window = window }

    public mutating func add(bytes: Int64, at time: TimeInterval) {
        samples.append(Sample(time: time, bytes: bytes))
        while samples.count > 2, let first = samples.first, time - first.time > window {
            samples.removeFirst()
        }
    }

    public var bytesPerSecond: Double {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        return max(0, Double(last.bytes - first.bytes) / (last.time - first.time))
    }

    public func secondsRemaining(total: Int64?, received: Int64) -> TimeInterval? {
        guard let total, bytesPerSecond > 0 else { return nil }
        return Double(max(0, total - received)) / bytesPerSecond
    }

    public mutating func reset() { samples.removeAll() }
}
