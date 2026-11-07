import Foundation
import os

public enum Log {
    private static let subsystem = "com.offlinevault.app"
    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let updates = Logger(subsystem: subsystem, category: "updates")
    public static let process = Logger(subsystem: subsystem, category: "process")
    public static let llm = Logger(subsystem: subsystem, category: "llm")
    public static let kiwix = Logger(subsystem: subsystem, category: "kiwix")
    public static let youtube = Logger(subsystem: subsystem, category: "youtube")
    public static let pages = Logger(subsystem: subsystem, category: "pages")
    public static let db = Logger(subsystem: subsystem, category: "db")
}

/// A user-facing error: every failure surfaced to the UI carries a plain-language message and a recovery hint.
public struct UserFacingError: LocalizedError, Equatable, Hashable {
    public let title: String
    public let message: String
    public let recovery: String?

    public init(_ title: String, message: String, recovery: String? = nil) {
        self.title = title
        self.message = message
        self.recovery = recovery
    }

    public var errorDescription: String? { "\(title): \(message)" }
    public var recoverySuggestion: String? { recovery }
}

public extension Error {
    /// Converts any error into something a user can act on.
    var userFacing: UserFacingError {
        if let u = self as? UserFacingError { return u }
        let ns = self as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                return UserFacingError("No connection", message: "The update service could not be reached.", recovery: "Check your internet connection and try again. Your existing library keeps working offline.")
            case NSURLErrorTimedOut:
                return UserFacingError("Timed out", message: "The server did not respond in time.", recovery: "Try again in a moment.")
            case NSURLErrorCancelled:
                return UserFacingError("Cancelled", message: "The operation was cancelled.", recovery: nil)
            default: break
            }
        }
        return UserFacingError("Something went wrong", message: ns.localizedDescription, recovery: nil)
    }
}
