import Foundation

/// Token bucket shared by connections (spec §5.7). The burst capacity is a quarter second of traffic:
/// a larger bucket lets short downloads and segment tails run past the limit.
public final class SpeedLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private var rate: Int64
    private var tokens: Double
    private var last: TimeInterval
    private static let burstSeconds = 0.25

    public init(bytesPerSecond: Int64, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.rate = max(0, bytesPerSecond)
        self.tokens = Double(max(0, bytesPerSecond)) * Self.burstSeconds
        self.last = now()
    }

    public func setRate(_ bytesPerSecond: Int64) {
        lock.withLock {
            refill()
            rate = max(0, bytesPerSecond)
            tokens = min(tokens, Double(rate) * Self.burstSeconds)
        }
    }

    /// Records `bytes` as transferred and returns how long the caller should stop reading.
    public func consume(_ bytes: Int) -> TimeInterval {
        lock.withLock {
            guard rate > 0 else { return 0 }
            refill()
            tokens -= Double(bytes)
            return tokens >= 0 ? 0 : -tokens / Double(rate)
        }
    }

    private func refill() {
        let t = now()
        tokens = min(Double(rate) * Self.burstSeconds, tokens + (t - last) * Double(rate))
        last = t
    }
}
