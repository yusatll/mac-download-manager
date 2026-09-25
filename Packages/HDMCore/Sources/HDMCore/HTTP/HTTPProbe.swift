import Foundation

public enum ProbeError: Error, Equatable, Sendable {
    case http(Int)
    case notHTTP
}

/// Reads only the response headers of a download (for dialogs), then cancels the body.
public enum HTTPProbe {
    public static func probe(url: URL, headers: [String: String] = [:], timeout: TimeInterval = 15) async throws -> ProbeResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await session.bytes(for: request)
        bytes.task.cancel()
        guard let http = response as? HTTPURLResponse else { throw ProbeError.notHTTP }
        let result = ProbeResult(response: http)
        guard http.statusCode == 200 || http.statusCode == 206 || result.isEmptyFile else { throw ProbeError.http(http.statusCode) }
        return result
    }
}
