import Foundation
import Testing
import os
@testable import HDMCore

final class FakeClock: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0.0)
    var now: TimeInterval { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

@Suite struct RateTests {
    @Test func unlimitedNeverPauses() {
        let limiter = SpeedLimiter(bytesPerSecond: 0)
        #expect(limiter.consume(10_000_000) == 0)
    }

    @Test func tokenBucketComputesPause() {
        let clock = FakeClock()
        let limiter = SpeedLimiter(bytesPerSecond: 1000, now: { clock.now })
        // Burst capacity is a quarter second of traffic, so short transfers cannot slip past the limit.
        #expect(limiter.consume(250) == 0)
        #expect(abs(limiter.consume(500) - 0.5) < 0.0001)
        clock.advance(1)
        #expect(limiter.consume(250) == 0)
        #expect(abs(limiter.consume(250) - 0.25) < 0.0001)
        limiter.setRate(0)
        #expect(limiter.consume(1_000_000) == 0)
    }

    @Test func meterAveragesOverWindow() {
        var meter = SpeedMeter(window: 3)
        meter.add(bytes: 0, at: 0)
        meter.add(bytes: 1000, at: 1)
        meter.add(bytes: 2000, at: 2)
        #expect(meter.bytesPerSecond == 1000)
        #expect(meter.secondsRemaining(total: 5000, received: 2000) == 3)
        #expect(meter.secondsRemaining(total: nil, received: 2000) == nil)
        meter.add(bytes: 12000, at: 10)
        #expect(meter.bytesPerSecond == 1250)
        meter.reset()
        #expect(meter.bytesPerSecond == 0)
    }

    @Test func backoffDoublesAndCaps() {
        #expect(RetryPolicy.delay(forAttempt: 1) == 1)
        #expect(RetryPolicy.delay(forAttempt: 2) == 2)
        #expect(RetryPolicy.delay(forAttempt: 3) == 4)
        #expect(RetryPolicy.delay(forAttempt: 6) == 30)
        #expect(RetryPolicy.delay(forAttempt: 40) == 30)
    }
}
