import Foundation

/// Token bucket shared by connections (spec §5.7). Capacity equals one second of traffic.
public final class SpeedLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private var rate: Int64
    private var tokens: Double
    private var last: TimeInterval

    public init(bytesPerSecond: Int64, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.rate = max(0, bytesPerSecond)
        self.tokens = Double(max(0, bytesPerSecond))
        self.last = now()
    }

    public func setRate(_ bytesPerSecond: Int64) {
        lock.withLock {
            refill()
            rate = max(0, bytesPerSecond)
            tokens = min(tokens, Double(rate))
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
        tokens = min(Double(rate), tokens + (t - last) * Double(rate))
        last = t
    }
}
