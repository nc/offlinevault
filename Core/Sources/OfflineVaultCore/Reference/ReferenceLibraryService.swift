import Foundation

/// A reference book (one ZIM) as reported by the engine.
public struct ReferenceBook: Equatable, Sendable, Identifiable {
    public var name: String
    public var title: String
    public var description: String?
    public var language: String?
    public var articleCount: Int64?
    public var mediaCount: Int64?
    public var mainPath: String?
    /// Content date (yyyy-MM-dd) from the OPDS feed.
    public var updated: String?
    public var id: String { name }
    public init(name: String, title: String, description: String? = nil, language: String? = nil, articleCount: Int64? = nil, mediaCount: Int64? = nil, mainPath: String? = nil, updated: String? = nil) {
        self.name = name; self.title = title; self.description = description; self.language = language; self.articleCount = articleCount; self.mediaCount = mediaCount; self.mainPath = mainPath; self.updated = updated
    }
}

/// One search hit inside a book.
public struct ReferenceHit: Equatable, Sendable, Identifiable {
    public var bookName: String
    public var title: String
    /// Article path within the book, e.g. `A/Water_purification` or `Water_purification`.
    public var path: String
    public var snippet: String
    public var wordCount: Int?
    public var id: String { bookName + "/" + path }
    public init(bookName: String, title: String, path: String, snippet: String, wordCount: Int? = nil) {
        self.bookName = bookName; self.title = title; self.path = path; self.snippet = snippet; self.wordCount = wordCount
    }
}

/// All ZIM access goes through this protocol so the engine (kiwix-serve today) can be swapped without touching the UI.
public protocol ReferenceLibraryService: AnyObject, Sendable {
    var isRunning: Bool { get }
    var engineDescription: String { get }
    /// (Re)starts the engine serving exactly these ZIM files.
    func start(zimFiles: [URL]) async throws
    func stop()
    func books() async throws -> [ReferenceBook]
    func search(_ query: String, books: [String]?, limit: Int) async throws -> [ReferenceHit]
    /// Plain-text content of an article (for retrieval passages).
    func articleText(bookName: String, path: String) async throws -> String
    func articleURL(bookName: String, path: String) -> URL
    func mainPageURL(bookName: String) -> URL
    /// Base URL the viewer may load from (used to restrict WKWebView navigation).
    var baseURL: URL { get }
}
