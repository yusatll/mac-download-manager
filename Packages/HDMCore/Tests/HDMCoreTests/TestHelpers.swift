import Foundation

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hdm-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

let fastBackoff: @Sendable (Int) -> TimeInterval = { _ in 0.05 }

struct WaitTimeout: Error {}

@MainActor
func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw WaitTimeout() }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}
