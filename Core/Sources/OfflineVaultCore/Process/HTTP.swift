import Foundation

/// Tiny helpers for talking to localhost helpers.
public enum LocalHTTP {
    public static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    public static func isHealthy(_ url: URL, timeout: TimeInterval = 2) async -> Bool {
        var req = URLRequest(url: url); req.timeoutInterval = timeout
        guard let (_, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    public static func get(_ url: URL, timeout: TimeInterval = 30) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url); req.timeoutInterval = timeout
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
