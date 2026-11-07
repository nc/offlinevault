import Foundation

/// A response body delivered as `Data` chunks at the rate URLSession receives them. `URLSession.bytes(for:)` hands
/// out one byte per await, which caps a download at a few MB/s regardless of the link (measured 2 MB/s from a local
/// server); the delegate path delivers whole packets. Backpressure: past `highWater` buffered bytes the task is
/// suspended until the consumer reports that it has written them.
final class ChunkedBody: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let highWater = 32 << 20
    static let lowWater = 8 << 20

    private let lock = NSLock()
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var buffered = 0
    private var suspended = false
    private var finished = false
    private var response: CheckedContinuation<URLResponse, Error>?
    private var chunkContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    let chunks: AsyncThrowingStream<Data, Error>

    init(configuration: URLSessionConfiguration) {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        chunks = AsyncThrowingStream { continuation = $0 }
        super.init()
        chunkContinuation = continuation
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Starts the request and returns once the headers are in; the body then streams through `chunks`.
    func start(_ request: URLRequest) async throws -> URLResponse {
        try await withCheckedThrowingContinuation { cont in
            lock.withLock { response = cont }
            let t = session.dataTask(with: request)
            lock.withLock { task = t }
            t.resume()
        }
    }

    /// The consumer has written `count` bytes to disk; resumes the transfer when the buffer has drained enough.
    func consumed(_ count: Int) {
        lock.withLock {
            buffered -= count
            if suspended, buffered <= Self.lowWater { suspended = false; task?.resume() }
        }
    }

    func cancel() {
        lock.withLock { task?.cancel() }
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let cont = lock.withLock { () -> CheckedContinuation<URLResponse, Error>? in let c = self.response; self.response = nil; return c }
        cont?.resume(returning: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            buffered += data.count
            if !suspended, buffered > Self.highWater { suspended = true; dataTask.suspend() }
        }
        chunkContinuation?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let pendingResponse = lock.withLock { () -> CheckedContinuation<URLResponse, Error>? in
            finished = true
            let c = response; response = nil; return c
        }
        if let error {
            pendingResponse?.resume(throwing: error)
            chunkContinuation?.finish(throwing: error)
        } else {
            pendingResponse?.resume(throwing: URLError(.badServerResponse))
            chunkContinuation?.finish()
        }
        session.finishTasksAndInvalidate()
    }
}
