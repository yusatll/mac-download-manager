import Foundation

public enum RetryPolicy {
    /// 1, 2, 4, 8, 16, 30, 30 … seconds.
    @Sendable public static func delay(forAttempt attempt: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, attempt - 1))))
    }
}
