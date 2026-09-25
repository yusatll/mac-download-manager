import Foundation
import os

enum DataOutcome: Sendable {
    case more
    case done
    case failed(FailureReason)
}

enum ConnectionResult: Sendable, Equatable {
    case segmentDone
    case endOfStream
    case cancelled
    case rejected
    case fatal(FailureReason)
    case failed(String)
}

struct ConnectionHandlers: Sendable {
    /// Decides whether to accept the response. Data only starts flowing after this returns.
    var onResponse: @Sendable (HTTPURLResponse) async -> Bool
    /// Called serially on the connection's queue for every received chunk.
    var onData: @Sendable (Data) -> DataOutcome
    var onComplete: @Sendable (ConnectionResult) -> Void
}

/// One ranged HTTP request on its **own** URLSession, so every connection is a separate TCP connection
/// (a shared session would multiplex them over one HTTP/2 connection and nothing would get faster).
final class Connection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "hdm.connection")
    private let handlers: ConnectionHandlers
    private let limiters: [SpeedLimiter]
    private let stopReason = OSAllocatedUnfairLock<ConnectionResult?>(initialState: nil)
    private var session: URLSession!
    private var task: URLSessionDataTask!

    init(request: URLRequest, timeout: TimeInterval, limiters: [SpeedLimiter], handlers: ConnectionHandlers) {
        self.handlers = handlers
        self.limiters = limiters
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        task = session.dataTask(with: request)
    }

    func start() { task.resume() }

    func cancel() {
        markStopped(.cancelled)
        task.cancel()
    }

    private func markStopped(_ reason: ConnectionResult) {
        stopReason.withLock { if $0 == nil { $0 = reason } }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        guard let http = response as? HTTPURLResponse else {
            markStopped(.failed("Not an HTTP response"))
            return .cancel
        }
        if stopReason.withLock({ $0 }) != nil { return .cancel }
        let accepted = await handlers.onResponse(http)
        if !accepted { markStopped(.rejected) }
        return accepted ? .allow : .cancel
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard stopReason.withLock({ $0 }) == nil else { return }
        switch handlers.onData(data) {
        case .more:
            let pause = limiters.map { $0.consume(data.count) }.max() ?? 0
            if pause > 0.005 {
                dataTask.suspend()
                queue.asyncAfter(deadline: .now() + pause) { dataTask.resume() }
            }
        case .done:
            markStopped(.segmentDone)
            dataTask.cancel()
        case .failed(let reason):
            markStopped(.fatal(reason))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: ConnectionResult
        if let stopped = stopReason.withLock({ $0 }) {
            result = stopped
        } else if let error {
            result = .failed(error.localizedDescription)
        } else {
            result = .endOfStream
        }
        session.finishTasksAndInvalidate()
        handlers.onComplete(result)
    }
}
