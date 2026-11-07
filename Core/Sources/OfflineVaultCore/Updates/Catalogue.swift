import Foundation

/// The `catalogue` artefact: human-readable metadata for the content the service publishes.
/// Stored at `index/catalogue.json`. Optional for the app to function; it enriches the Library tab before kiwix-serve reports book metadata.
/// How a book should be used by retrieval and grouped in the Library tab.
public enum BookRole: String, Codable, CaseIterable, Sendable {
    case procedural, encyclopaedic, reference
    public var title: String {
        switch self {
        case .procedural: return "Field guides & manuals"
        case .encyclopaedic: return "Encyclopaedias"
        case .reference: return "Technical reference"
        }
    }
    /// Retrieval weight when the question is safety-critical / procedural.
    public var proceduralBoost: Double {
        switch self { case .procedural: return 1.35; case .reference: return 1.1; case .encyclopaedic: return 1.0 }
    }
}

public struct Catalogue: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var artefactId: String
        public var title: String
        public var description: String?
        public var language: String?
        public var licence: String?
        public var attribution: String?
        public var articleCount: Int64?
        /// For ZIMs: the kiwix book name (file name without .zim). For models: the GGUF file name.
        public var fileName: String?
        /// "procedural" (field manuals, first aid, how-to — preferred for what-do-I-do questions), "encyclopaedic", "reference".
        public var role: String?
        public var tier: String?
        public var publisher: String?
        public var sourceURL: String?
        public var id: String { artefactId }
        public init(artefactId: String, title: String, description: String? = nil, language: String? = nil, licence: String? = nil, attribution: String? = nil, articleCount: Int64? = nil, fileName: String? = nil, role: String? = nil, tier: String? = nil, publisher: String? = nil, sourceURL: String? = nil) {
            self.artefactId = artefactId; self.title = title; self.description = description; self.language = language
            self.licence = licence; self.attribution = attribution; self.articleCount = articleCount; self.fileName = fileName
            self.role = role; self.tier = tier; self.publisher = publisher; self.sourceURL = sourceURL
        }
        public var bookRole: BookRole { BookRole(rawValue: role ?? "") ?? .encyclopaedic }
    }
    public var catalogueVersion: String
    public var entries: [Entry]

    public init(catalogueVersion: String, entries: [Entry]) { self.catalogueVersion = catalogueVersion; self.entries = entries }

    public static func load(from url: URL) -> Catalogue? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Catalogue.self, from: data)
    }

    public func entry(forArtefact id: String) -> Entry? { entries.first { $0.artefactId == id } }
}
