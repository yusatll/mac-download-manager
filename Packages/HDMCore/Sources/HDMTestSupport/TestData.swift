import CryptoKit
import Foundation

public enum TestData {
    /// Deterministic pseudo-random bytes (LCG), so failures are reproducible.
    public static func random(count: Int, seed: UInt64 = 42) -> Data {
        var state = seed
        var data = Data(count: count)
        data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for index in 0..<count {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                buffer[index] = UInt8(truncatingIfNeeded: state >> 33)
            }
        }
        return data
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(fileAt url: URL) throws -> String {
        sha256(try Data(contentsOf: url))
    }
}
