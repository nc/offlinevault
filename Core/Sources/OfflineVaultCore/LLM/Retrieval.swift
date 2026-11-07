import Foundation

/// Where a retrieved passage came from. Encoded with chat messages so citations stay tappable after a relaunch.
public enum SourceRef: Codable, Equatable, Hashable, Sendable {
    case zimArticle(book: String, path: String, title: String)
    case page(id: String, title: String, url: String)
    case video(id: String, title: String, startSeconds: Double?)
    case document(id: String, title: String, page: Int)

    public var title: String {
        switch self {
        case .zimArticle(_, _, let t), .page(_, let t, _), .video(_, let t, _), .document(_, let t, _): return t
        }
    }
    public var kindLabel: String {
        switch self {
        case .zimArticle: return "Reference"
        case .page: return "Saved page"
        case .video: return "Video"
        case .document: return "Document"
        }
    }
    public var systemImage: String {
        switch self {
        case .zimArticle: return "books.vertical"
        case .page: return "doc.text"
        case .video: return "play.rectangle"
        case .document: return "doc.richtext"
        }
    }
    /// The book, manual, page or video a passage came from.
    public var originKey: String {
        switch self {
        case .zimArticle(let b, _, _): return "zim:\(b)"
        case .page(let id, _, _): return "page:\(id)"
        case .video(let id, _, _): return "video:\(id)"
        case .document(let id, _, _): return "doc:\(id)"
        }
    }
    /// Identity used for de-duplication (same article found by two queries).
    public var dedupeKey: String {
        switch self {
        case .zimArticle(let b, let p, _): return "zim:\(b)/\(p)"
        case .page(let id, _, _): return "page:\(id)"
        case .video(let id, _, let s): return "video:\(id)@\(Int((s ?? -1) / 60))"
        case .document(let id, _, let page): return "doc:\(id)#\(page)"
        }
    }
}

public struct RetrievedPassage: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// 1-based label used in the prompt and in citations ([1], [2] …). Assigned by the coordinator.
    public var label: Int
    public var source: SourceRef
    public var text: String
    public var score: Double
    public var retriever: String
    /// The article's own keyword line, for a Field Guide procedure: what the author says it is about.
    public var keywords: [String]?
    public var id: String { "\(label):\(source.dedupeKey)" }

    public init(label: Int = 0, source: SourceRef, text: String, score: Double, retriever: String, keywords: [String]? = nil) {
        self.label = label; self.source = source; self.text = text; self.score = score; self.retriever = retriever; self.keywords = keywords
    }
}

public protocol Retriever: Sendable {
    var name: String { get }
    func retrieve(_ query: String, limit: Int) async throws -> [RetrievedPassage]
}

/// How a reference hit becomes passage text.
public enum PassageStyle: Sendable {
    /// The `maxChars` of the article around the most query terms; the search snippet below the third hit.
    case window(maxChars: Int)
    /// The Field Guide procedure (`FieldGuideProcedure`) for the three hits the coordinator reserves slots for. They
    /// share `budget` chars in proportion to the query terms each matches, each capped at `maxChars`; a hit whose
    /// procedure matches no term is dropped, since the search matched it on the sources appended below the procedure.
    case procedure(maxChars: Int, budget: Int)
}

/// Searches installed ZIMs through the reference engine and expands top hits into article passages.
public struct ReferenceRetriever: Retriever {
    public let name: String
    public let service: ReferenceLibraryService
    /// Book name → role, so field manuals outrank encyclopaedia articles on safety-critical questions.
    public let bookRoles: @Sendable () -> [String: BookRole]
    /// Books to search (nil: every served book).
    public let books: @Sendable () -> [String]?
    /// Probe every content term on its own rather than the four longest. In a small book the short tokens ("cpr",
    /// "ors", "psi") are the specific ones; across an encyclopaedia the same probes pull in unrelated articles.
    public let probeEveryTerm: Bool
    public let style: PassageStyle
    public init(service: ReferenceLibraryService, bookRoles: @escaping @Sendable () -> [String: BookRole] = { [:] }, name: String = "reference",
                books: @escaping @Sendable () -> [String]? = { nil }, probeEveryTerm: Bool = false, style: PassageStyle = .window(maxChars: 900)) {
        self.service = service; self.bookRoles = bookRoles; self.name = name; self.books = books; self.probeEveryTerm = probeEveryTerm; self.style = style
    }

    public func retrieve(_ query: String, limit: Int) async throws -> [RetrievedPassage] {
        guard service.isRunning else { return [] }
        let books = books()
        if let books, books.isEmpty { return [] }
        let terms = RetrievalCoordinator.terms(in: query)
        var hits = try await Self.multiQuerySearch(service: service, query: query, terms: terms, limit: limit, books: books, probeEveryTerm: probeEveryTerm)
        if Prompting.isSafetyCritical(query) {
            // Field manuals and first-aid texts get a boost, and the best one is guaranteed a slot in the top two
            // passages so the model always sees procedural guidance next to encyclopaedic background.
            let roles = bookRoles()
            hits = hits.map { ($0.0, $0.1 * (roles[$0.0.bookName]?.proceduralBoost ?? 1.0)) }.sorted { $0.1 > $1.1 }
            if let idx = hits.firstIndex(where: { roles[$0.0.bookName] == .procedural }), idx > 1 {
                let h = hits.remove(at: idx); hits.insert(h, at: 1)
            }
        }
        let top = Array(hits.prefix(limit))
        var articles: [String] = []
        for (i, (h, _)) in top.enumerated() { articles.append(i < 3 ? ((try? await service.articleText(bookName: h.bookName, path: h.path)) ?? "") : "") }
        let texts: [String?]
        var keywords: [[String]?] = Array(repeating: nil, count: top.count)
        switch style {
        case .window(let maxChars):
            texts = zip(top, articles).map { h, article in article.isEmpty ? h.0.snippet : HTMLText.bestWindow(in: article, queryTerms: terms, maxChars: maxChars) }
        case .procedure(let maxChars, let budget):
            texts = FieldGuideProcedure.passages(articles.prefix(3).map(FieldGuideProcedure.section(of:)), terms: terms, maxChars: maxChars, budget: budget)
            for (i, article) in articles.prefix(3).enumerated() { keywords[i] = FieldGuideProcedure.keywords(of: article) }
        }
        return zip(zip(top, texts), keywords).compactMap { pair, keywords in
            let (hit, text) = pair
            guard let text, !text.isEmpty else { return nil }
            return RetrievedPassage(source: .zimArticle(book: hit.0.bookName, path: hit.0.path, title: hit.0.title), text: text, score: hit.1, retriever: name, keywords: keywords)
        }
    }

    /// libzim ANDs all query terms, so a long question usually matches nothing. Run the full query plus
    /// single-term queries for the most specific terms and fuse the rankings (reciprocal rank fusion).
    static func multiQuerySearch(service: ReferenceLibraryService, query: String, terms: [String], limit: Int, books: [String]? = nil, probeEveryTerm: Bool = false) async throws -> [(ReferenceHit, Double)] {
        var queries: [(String, Double)] = [(terms.isEmpty ? query : terms.joined(separator: " "), 2.0)]
        // Single-term probes only for specific-looking words; short words ("there", "wait") pull in unrelated articles.
        let specific = probeEveryTerm ? terms : Array(terms.filter { $0.count >= 4 }.sorted { $0.count > $1.count }.prefix(4))
        if terms.count > 1 { for t in specific { queries.append((t, 1.0)) } }
        if terms.count > 2 { queries.append((specific.prefix(2).joined(separator: " "), 1.5)) }
        // Results are folded in query order, not arrival order, so a tie sums to the same float every run.
        var results = [[ReferenceHit]](repeating: [], count: queries.count)
        await withTaskGroup(of: (Int, [ReferenceHit]).self) { group in
            for (i, (q, _)) in queries.enumerated() { group.addTask { (i, (try? await service.search(q, books: books, limit: limit)) ?? []) } }
            for await (i, hits) in group { results[i] = hits }
        }
        var scores: [String: (ReferenceHit, Double)] = [:]
        for (hits, (_, w)) in zip(results, queries) {
            for (rank, h) in hits.enumerated() {
                let s = w / Double(rank + 1)
                if let existing = scores[h.id] { scores[h.id] = (existing.0, existing.1 + s) } else { scores[h.id] = (h, s) }
            }
        }
        return scores.values.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
    }
}

/// FTS5 over captured page chunks.
public struct PageRetriever: Retriever {
    public let name = "pages"
    public let pages: PageService
    public init(pages: PageService) { self.pages = pages }
    public func retrieve(_ query: String, limit: Int) async throws -> [RetrievedPassage] {
        try pages.search(RetrievalCoordinator.keywordQuery(query), limit: limit, anyTerm: true).map { hit in
            RetrievedPassage(source: .page(id: hit.page.id, title: hit.page.title, url: hit.page.url.absoluteString), text: hit.chunkText, score: hit.score, retriever: name)
        }
    }
}

/// FTS5 over PDF document chunks (page-aware).
public struct DocumentRetriever: Retriever {
    public let name = "documents"
    public let documents: DocumentService
    public init(documents: DocumentService) { self.documents = documents }
    public func retrieve(_ query: String, limit: Int) async throws -> [RetrievedPassage] {
        let boost = Prompting.isSafetyCritical(query) ? BookRole.procedural.proceduralBoost : 1.0
        return try documents.search(RetrievalCoordinator.keywordQuery(query), limit: limit, anyTerm: true).map { hit in
            RetrievedPassage(source: .document(id: hit.document.id, title: hit.document.title, page: hit.page), text: hit.chunkText, score: hit.score * boost, retriever: name)
        }
    }
}

/// FTS5 over video titles/descriptions and transcript segments (with timestamps).
public struct VideoRetriever: Retriever {
    public let name = "videos"
    public let videos: VideoLibraryService
    public init(videos: VideoLibraryService) { self.videos = videos }
    public func retrieve(_ query: String, limit: Int) async throws -> [RetrievedPassage] {
        var out: [RetrievedPassage] = []
        let q = RetrievalCoordinator.keywordQuery(query)
        for hit in try videos.searchTranscripts(q, limit: limit, anyTerm: true) {
            out.append(RetrievedPassage(source: .video(id: hit.video.id, title: hit.video.title, startSeconds: hit.startSeconds), text: "[\(DurationFormat.string(hit.startSeconds))] \(hit.text)", score: hit.score, retriever: name))
        }
        for hit in try videos.searchMetadata(q, limit: max(2, limit / 2), anyTerm: true) where hit.video.status == .downloaded {
            let desc = (hit.video.description ?? "").prefix(600)
            out.append(RetrievedPassage(source: .video(id: hit.video.id, title: hit.video.title, startSeconds: nil), text: "Video “\(hit.video.title)” by \(hit.video.channel ?? "unknown"). \(desc)", score: hit.score * 0.8, retriever: name))
        }
        return out
    }
}

/// Runs all retrievers, normalises scores per retriever, de-duplicates and returns the top passages with labels.
public struct RetrievalCoordinator: Sendable {
    public var retrievers: [Retriever]
    public var limitPerRetriever = 6
    public var finalLimit = 6
    public var maxPromptChars = 6000
    /// Retriever name → passages it places before the merged ranking.
    public var reservedSlots: [String: Int] = [:]
    /// Passages one book or manual may occupy. A 300-page manual returns many near-duplicate chunks that score close
    /// to its best one; without a cap they take every slot the min-max normalisation leaves.
    public var maxPassagesPerOrigin = 2
    /// Retriever name → most passages it may occupy.
    public var maxPassagesPerRetriever: [String: Int] = [:]

    public init(retrievers: [Retriever], reservedSlots: [String: Int] = [:]) { self.retrievers = retrievers; self.reservedSlots = reservedSlots }

    public static let fieldGuideRetriever = "fieldguide"
    /// 3700 chars holds 95% of the procedures in fieldguide_en_2026-10b whole (p50 2055, p95 3619, max 4636); the
    /// 4800-char budget leaves a fifth of the prompt for the manuals and encyclopaedias.
    public static let fieldGuideStyle = PassageStyle.procedure(maxChars: 3700, budget: 4800)
    /// The lead rule's knobs. The default is the rule the app applies; retrievaltool measures the others over the eval
    /// questions and prints the table (scripts/eval/results/README.md keeps it).
    public struct FieldGuideLeadPolicy: Sendable, Equatable {
        /// Whether a question term in the article's title or keywords counts, and ranks passages ahead of the text count.
        public var topic: Bool
        /// Title or keyword terms the lead must contain.
        public var minTopic: Int
        /// Question terms the lead must contain in all, every one of them for a shorter question.
        public var minMatched: Int
        /// Share of the question's terms the lead must contain.
        public var minCoverage: Double
        /// Terms the lead must contain beyond the best other Field Guide passage when the two tie on topic terms.
        public var margin: Int
        /// Only the Field Guide retriever's first passage may lead.
        public var firstOnly: Bool
        /// Match a term to a word that shares its stem ("burned", "burns"), not only to a word it starts.
        public var stem: Bool
        public init(topic: Bool = false, minTopic: Int = 0, minMatched: Int = 2, minCoverage: Double = 0, margin: Int = 0, firstOnly: Bool = false, stem: Bool = false) {
            self.topic = topic; self.minTopic = minTopic; self.minMatched = minMatched; self.minCoverage = minCoverage; self.margin = margin; self.firstOnly = firstOnly; self.stem = stem
        }
    }
    /// What a Field Guide passage must satisfy before the app shows it to the reader ahead of the answer: a question
    /// term in its title or keywords, three terms (and 60% of the question's) in all, and two terms clear of a passage
    /// it ties with on topic. Over the eval questions (results/retrieval/2026-11-07-lead-*.json) this leads 38 of 101
    /// with 37 gold and never on a catalogue question; the text-count rule it replaced led 97 with 68 gold.
    public static let fieldGuideLeadPolicy = FieldGuideLeadPolicy(topic: true, minTopic: 1, minMatched: 3, minCoverage: 0.6, margin: 2, stem: true)

    /// The app's retriever set over a library; the app, ReadinessCheck and retrievaltool all use it, so the harness
    /// measures what the app does. The numbers behind these settings are in scripts/eval/results/README.md.
    public static func standard(reference: ReferenceLibraryService, documents: DocumentService, pages: PageService, videos: VideoLibraryService, books: @escaping @Sendable () -> [ZimBook], fieldGuide: PassageStyle = fieldGuideStyle) -> RetrievalCoordinator {
        let roles: @Sendable () -> [String: BookRole] = { Dictionary(uniqueKeysWithValues: books().map { ($0.name, $0.role ?? .encyclopaedic) }) }
        let fieldGuides: @Sendable () -> [String]? = { books().filter(\.isFieldGuide).map(\.name) }
        var c = RetrievalCoordinator(retrievers: [
            ReferenceRetriever(service: reference, bookRoles: roles, name: fieldGuideRetriever, books: fieldGuides, probeEveryTerm: true, style: fieldGuide),
            ReferenceRetriever(service: reference, bookRoles: roles),
            DocumentRetriever(documents: documents), PageRetriever(pages: pages), VideoRetriever(videos: videos),
        ], reservedSlots: [fieldGuideRetriever: 3])
        c.finalLimit = 8
        c.maxPassagesPerRetriever = [documentRetriever: 1]
        return c
    }

    public static let documentRetriever = "documents"

    static let stopWords: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "how", "do", "i", "is", "are", "what", "can", "should", "my", "you", "it", "this", "that", "be", "from", "at", "by", "if", "when", "does", "about",
        "there", "here", "hey", "hi", "hello", "yo", "thanks", "thank", "please", "ok", "okay", "sure", "yes", "no", "me", "we", "us", "they", "them", "your", "our", "their", "his", "her", "its", "was", "were", "will", "would", "could", "have", "has", "had",
        "not", "but", "so", "just", "like", "any", "some", "more", "also", "than", "then", "into", "out", "up", "down", "over", "again", "tell", "know", "want", "need", "help", "which", "who", "why", "where", "much", "many", "get", "give", "make", "use", "am", "did", "done", "good", "morning", "evening", "afternoon", "bye", "goodbye", "test", "testing"]

    /// Content-bearing terms of a message (stop words and chit-chat removed). Empty for greetings / small talk.
    public static func terms(in query: String) -> [String] {
        query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 && !stopWords.contains($0) }
    }

    /// Greetings and small talk get no retrieval at all, so the model is never handed an unrelated source to parrot.
    public static func shouldRetrieve(_ query: String) -> Bool { !terms(in: query).isEmpty }

    /// The Field Guide passage to show the reader before the model's answer: the one that contains the most of the
    /// question's terms (in its title and keywords first, then anywhere), the earlier label on a tie, when it satisfies
    /// `policy`. Nil otherwise, so an unrelated procedure is never put first; on a safety-critical question the lead
    /// stands alone, so a wrong one is worse than none.
    public static func fieldGuideLead(for query: String, in passages: [RetrievedPassage], policy: FieldGuideLeadPolicy = fieldGuideLeadPolicy) -> RetrievedPassage? {
        let terms = terms(in: query)
        let needed = min(policy.minMatched, terms.count)
        guard needed > 0 else { return nil }
        struct Scored { var passage: RetrievedPassage; var topic: Int; var matched: Int }
        let scored = passages.filter { $0.retriever == fieldGuideRetriever }.map { p -> Scored in
            let inText = FieldGuideProcedure.matched(in: p.text, terms: terms, stem: policy.stem)
            guard policy.topic else { return Scored(passage: p, topic: 0, matched: inText.count) }
            let inTopic = FieldGuideProcedure.matched(in: ([p.source.title] + (p.keywords ?? [])).joined(separator: ". "), terms: terms, stem: policy.stem)
            return Scored(passage: p, topic: inTopic.count, matched: Set(inText).union(inTopic).count)
        }
        let ahead: (Scored, Scored) -> Bool = { a, b in
            a.topic != b.topic ? a.topic > b.topic : a.matched != b.matched ? a.matched > b.matched : a.passage.label < b.passage.label
        }
        let candidates = policy.firstOnly ? scored.min { $0.passage.label < $1.passage.label }.map { [$0] } ?? [] : scored
        guard let best = candidates.sorted(by: ahead).first, best.topic >= policy.minTopic, best.matched >= needed,
              Double(best.matched) >= policy.minCoverage * Double(terms.count) else { return nil }
        if let runnerUp = scored.filter({ $0.passage.label != best.passage.label }).sorted(by: ahead).first,
           runnerUp.topic == best.topic, best.matched - runnerUp.matched < policy.margin { return nil }
        return best.passage
    }

    /// Stop-word-free form of a question, used for FTS "any term" matching.
    public static func keywordQuery(_ query: String) -> String {
        let t = terms(in: query)
        return t.isEmpty ? query : t.joined(separator: " ")
    }

    public func retrieve(_ query: String) async -> [RetrievedPassage] {
        guard Self.shouldRetrieve(query) else { return [] }
        // Groups keep the retrievers' order whatever finishes first, so equal scores resolve the same way every run.
        var groups = [[RetrievedPassage]](repeating: [], count: retrievers.count)
        await withTaskGroup(of: (Int, [RetrievedPassage]).self) { group in
            for (i, r) in retrievers.enumerated() {
                group.addTask { (i, (try? await r.retrieve(query, limit: limitPerRetriever)) ?? []) }
            }
            for await (i, g) in group { groups[i] = g }
        }
        return Self.merge(groups, finalLimit: finalLimit, maxChars: maxPromptChars, reserved: reservedSlots, perOrigin: maxPassagesPerOrigin, perRetriever: maxPassagesPerRetriever)
    }

    /// Per-retriever min-max normalisation, reserved slots first, then global sort and de-dup.
    public static func merge(_ groups: [[RetrievedPassage]], finalLimit: Int, maxChars: Int, reserved: [String: Int] = [:], perOrigin: Int = .max, perRetriever: [String: Int] = [:]) -> [RetrievedPassage] {
        var normalised: [[RetrievedPassage]] = []
        for g in groups where !g.isEmpty {
            let maxScore = g.map(\.score).max() ?? 1
            let minScore = g.map(\.score).min() ?? 0
            normalised.append(g.map { p in
                var p = p
                p.score = maxScore > minScore ? 0.5 + 0.5 * (p.score - minScore) / (maxScore - minScore) : 1.0
                return p
            }.sorted { $0.score > $1.score })
        }
        var seen = Set<String>()
        var perOriginCount: [String: Int] = [:]
        var perRetrieverCount: [String: Int] = [:]
        var out: [RetrievedPassage] = []
        var chars = 0
        func take(_ p: RetrievedPassage, capped: Bool = true) {
            guard out.count < finalLimit, !capped || perOriginCount[p.source.originKey, default: 0] < perOrigin,
                  perRetrieverCount[p.retriever, default: 0] < perRetriever[p.retriever] ?? .max, seen.insert(p.source.dedupeKey).inserted else { return }
            guard chars + p.text.count <= maxChars || out.isEmpty else { return }
            chars += p.text.count
            perOriginCount[p.source.originKey, default: 0] += 1
            perRetrieverCount[p.retriever, default: 0] += 1
            var p = p
            p.label = out.count + 1
            out.append(p)
        }
        for g in normalised {
            if let n = g.first.flatMap({ reserved[$0.retriever] }) { for p in g.prefix(n) { take(p, capped: false) } }
        }
        normalised.flatMap { $0 }.sorted { $0.score > $1.score }.forEach { take($0) }
        return out
    }
}
