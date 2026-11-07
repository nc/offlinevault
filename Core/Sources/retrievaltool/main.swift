import Foundation
import OfflineVaultCore
import SQLite3

// retrievaltool: the app's retrieval with no model over every eval question. scripts/eval/README.md has the usage.
//
//   OFFLINEVAULT_BIN_DIR=../OfflineVault/Resources/bin swift run retrievaltool --library ../LibraryDev \
//       --questions ../scripts/eval/questions.yaml --python ../scripts/content/.venv/bin/python --out /tmp/retrieval.json

func usage() -> Never {
    FileHandle.standardError.write("usage: retrievaltool --library DIR --questions FILE [--out FILE] [--port N] [--python EXE] [--only ID] [--limit N] [--reserved N] [--per-origin N] [--doc-cap N] [--final-limit N] [--fg-cap N] [--fg-budget N] [--texts FILE]\n".data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    fflush(stdout)
    FileHandle.standardError.write("retrievaltool: \(message)\n".data(using: .utf8)!)
    exit(1)
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...i + 1); return v
}

guard let libraryPath = option("--library"), let questionsPath = option("--questions") else { usage() }
let outPath = option("--out")
let port = option("--port").flatMap(Int.init) ?? 18765
let python = option("--python") ?? "python3"
let only = option("--only")
let limit = option("--limit").flatMap(Int.init)
let reservedOverride = option("--reserved").flatMap(Int.init)
let perOriginOverride = option("--per-origin").flatMap(Int.init)
let docCapOverride = option("--doc-cap").flatMap(Int.init)
let finalLimitOverride = option("--final-limit").flatMap(Int.init)
let fieldGuideCap = option("--fg-cap").flatMap(Int.init)
let fieldGuideBudget = option("--fg-budget").flatMap(Int.init)
/// Where to write every Field Guide passage's text by question id, for unit-test fixtures and for reading what the app shows.
let textsPath = option("--texts")
guard args.isEmpty else { usage() }

// MARK: Questions

enum Target {
    case article(slug: String)
    case catalogue(id: String, title: String)
}

struct Question {
    var id: String
    var coverage: String
    var text: String
    var targets: [Target]
    var gold: [GoldFact]
}

/// A fact the answer must contain: every key group must match, a group matches on any of its alternatives.
struct GoldFact { var keyGroups: [[String]] }

var synonyms: [(String, String)] = []
func canonical(_ s: String) -> String {
    var out = s.lowercased()
    for (from, to) in synonyms { out = out.replacingOccurrences(of: from, with: to) }
    return out
}

func loadQuestions(_ path: String) throws -> [Question] {
    let data: Data
    if path.hasSuffix(".yaml") || path.hasSuffix(".yml") {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [python, "-c", "import sys, json, yaml; json.dump(yaml.safe_load(open(sys.argv[1])), sys.stdout)", path]
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run()
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { fail("\(python) could not convert \(path); install PyYAML or pass --python") }
    } else {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let items = root["questions"] as? [[String: Any]] else { fail("\(path): no `questions` list") }
    synonyms = ((root["synonyms"] as? [String: String]) ?? [:]).map { ($0.key.lowercased(), $0.value.lowercased()) }.sorted { $0.0.count > $1.0.count }
    return items.map { q in
        let sources = (q["sources"] as? [[String: Any]]) ?? []
        let gold = ((q["gold"] as? [[String: Any]]) ?? []).map { fact in
            GoldFact(keyGroups: ((fact["keys"] as? [String]) ?? []).map { $0.split(separator: "|").map { canonical(String($0)) } })
        }
        let targets: [Target] = sources.compactMap { s in
            if let slug = s["article"] as? String { return .article(slug: slug) }
            if let id = s["catalogue"] as? String { return .catalogue(id: id, title: (s["title"] as? String) ?? "") }
            return nil
        }
        return Question(id: q["id"] as? String ?? "", coverage: q["coverage"] as? String ?? "", text: q["question"] as? String ?? "", targets: targets, gold: gold)
    }
}

// MARK: Library

func snapshotDatabase(from source: URL, to dest: URL) throws {
    var src: OpaquePointer?, dst: OpaquePointer?
    guard sqlite3_open_v2(source.path, &src, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { fail("cannot open \(source.path) read-only") }
    defer { sqlite3_close(src) }
    guard sqlite3_open(dest.path, &dst) == SQLITE_OK else { fail("cannot create \(dest.path)") }
    defer { sqlite3_close(dst) }
    guard let backup = sqlite3_backup_init(dst, "main", src, "main") else { fail("backup init failed: \(String(cString: sqlite3_errmsg(dst)))") }
    let rc = sqlite3_backup_step(backup, -1)
    sqlite3_backup_finish(backup)
    guard rc == SQLITE_DONE else { fail("backup step returned \(rc)") }
}

let library = LibraryLayout(root: URL(fileURLWithPath: libraryPath))
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("retrievaltool-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
ProcessSupervisor.shared.pidFileURL = scratch.appendingPathComponent("helper-pids.json")
let dbURL = scratch.appendingPathComponent("library.sqlite")
try snapshotDatabase(from: library.databaseURL, to: dbURL)
let db = try IndexDatabase(url: dbURL)
let books = try db.zimBooks()
let documents = try DocumentService(layout: library, database: db).documents()

let zims = try FileManager.default.contentsOfDirectory(at: library.zim, includingPropertiesForKeys: nil).filter { $0.pathExtension == "zim" }
guard !zims.isEmpty else { fail("no ZIM files under \(library.zim.path)") }
let kiwix = KiwixServeService(port: port)
let started = Date()
kiwix.stateObserver = { state in print(String(format: "kiwix-serve %7.1fs: %@", Date().timeIntervalSince(started), state.label)) }
try await kiwix.start(zimFiles: zims)
guard kiwix.isRunning else { fail("kiwix-serve exited right after starting; is another harness or app already on port \(port)?") }
let served = try await kiwix.books()
print("kiwix-serve on \(port): \(served.count) books, \(documents.count) documents, \(books.count) zim_books rows")

var fieldGuideStyle = RetrievalCoordinator.fieldGuideStyle
if case .procedure(let cap, let budget) = fieldGuideStyle, fieldGuideCap != nil || fieldGuideBudget != nil { fieldGuideStyle = .procedure(maxChars: fieldGuideCap ?? cap, budget: fieldGuideBudget ?? budget) }
var coordinator = RetrievalCoordinator.standard(reference: kiwix, documents: DocumentService(layout: library, database: db), pages: PageService(layout: library, database: db),
                                                videos: VideoLibraryService(layout: library, database: db), books: { books }, fieldGuide: fieldGuideStyle)
if let reservedOverride { coordinator.reservedSlots = [RetrievalCoordinator.fieldGuideRetriever: reservedOverride] }
if let perOriginOverride { coordinator.maxPassagesPerOrigin = perOriginOverride }
if let docCapOverride { coordinator.maxPassagesPerRetriever[RetrievalCoordinator.documentRetriever] = docCapOverride }
if let finalLimitOverride { coordinator.finalLimit = finalLimitOverride }
print("field guide \(fieldGuideStyle), reserved slots \(coordinator.reservedSlots), passages per origin \(coordinator.maxPassagesPerOrigin), per retriever \(coordinator.maxPassagesPerRetriever), final limit \(coordinator.finalLimit), prompt chars \(coordinator.maxPromptChars)")

// MARK: Matching

func slug(ofZimPath path: String) -> String {
    var p = path.split(separator: "/").last.map(String.init) ?? path
    if p.hasSuffix(".html") { p.removeLast(5) }
    return p
}

func bookNames(forCatalogue id: String) -> Set<String> {
    Set(books.filter { ($0.artefactId ?? "").hasPrefix(id + "-") || $0.artefactId == id }.map(\.name))
}
func isInstalled(_ t: Target) -> Bool {
    switch t {
    case .article: return books.contains { $0.name.hasPrefix("fieldguide") }
    case .catalogue(let id, _): return id.hasPrefix("docs-") ? !documents.isEmpty : !bookNames(forCatalogue: id).isEmpty
    }
}

enum Match { case none, book, exact }
func match(_ p: RetrievedPassage, _ t: Target) -> Match {
    switch (p.source, t) {
    case (.zimArticle(let book, let path, _), .article(let s)):
        guard book.hasPrefix("fieldguide") else { return .none }
        return slug(ofZimPath: path) == s ? .exact : .book
    case (.zimArticle(let book, _, let title), .catalogue(let id, let cited)):
        guard bookNames(forCatalogue: id).contains(book) else { return .none }
        return title.caseInsensitiveCompare(cited) == .orderedSame ? .exact : .book
    case (.document(_, let title, _), .catalogue(let id, let cited)):
        guard id.hasPrefix("docs-") else { return .none }
        return title.localizedCaseInsensitiveContains(cited) ? .exact : .book
    default: return .none
    }
}

// MARK: Lead rules

typealias LeadPolicy = RetrievalCoordinator.FieldGuideLeadPolicy
/// The candidate rules, measured side by side in one run. The app's rule is `RetrievalCoordinator.fieldGuideLeadPolicy`.
let leadRules: [(name: String, policy: LeadPolicy)] = [
    ("text terms >= 2 (before 2026-11-07)", LeadPolicy()),
    ("(a) title or keyword term", LeadPolicy(topic: true, minTopic: 1)),
    ("(b) coverage >= 3 terms and half", LeadPolicy(minMatched: 3, minCoverage: 0.5)),
    ("(c) margin 1 over the runner-up", LeadPolicy(margin: 1)),
    ("(d) retriever rank 1 only", LeadPolicy(firstOnly: true)),
    ("(e) stemming", LeadPolicy(stem: true)),
    ("a+e", LeadPolicy(topic: true, minTopic: 1, stem: true)),
    ("a+b+e", LeadPolicy(topic: true, minTopic: 1, minMatched: 3, minCoverage: 0.5, stem: true)),
    ("a+b+c+e", LeadPolicy(topic: true, minTopic: 1, minMatched: 3, minCoverage: 0.5, margin: 1, stem: true)),
    ("a+b+e, margin 2", LeadPolicy(topic: true, minTopic: 1, minMatched: 3, minCoverage: 0.5, margin: 2, stem: true)),
    ("a+b+e, margin 2, coverage 0.6 (adopted)", LeadPolicy(topic: true, minTopic: 1, minMatched: 3, minCoverage: 0.6, margin: 2, stem: true)),
    ("a+d+e", LeadPolicy(topic: true, minTopic: 1, firstOnly: true, stem: true)),
    ("a+b+d+e", LeadPolicy(topic: true, minTopic: 1, minMatched: 3, minCoverage: 0.5, firstOnly: true, stem: true)),
]

func slug(of p: RetrievedPassage) -> String {
    if case .zimArticle(_, let path, _) = p.source { return slug(ofZimPath: path) }
    return p.source.dedupeKey
}

/// What the lead rules weigh for one Field Guide passage.
struct LeadEvidence: Encodable { var label: Int; var slug: String; var title: String; var inText: [String]; var inTitle: [String]; var inKeywords: [String] }

// MARK: Run

struct PassageRecord: Encodable { var label: Int; var retriever: String; var key: String; var title: String; var chars: Int; var score: Double }
struct Candidate: Encodable { var retriever: String; var rank: Int; var key: String; var title: String; var score: Double }
struct QuestionResult: Encodable {
    var id: String; var coverage: String; var question: String
    /// What each retriever offered, in its own order, before the merge.
    var candidates: [Candidate]
    var targets: [String]; var targetInstalled: Bool
    /// Label (1-based rank) of the first passage from the gold article, and of the first from the cited book at all.
    var exactRank: Int?
    var bookRank: Int?
    var goldFacts: Int
    var goldCovered: Int
    var goldCoveredByArticle: Int
    /// Slug of the Field Guide passage the app would show before the answer (`RetrievalCoordinator.fieldGuideLead`), and
    /// whether it is a gold article. A lead on a catalogue question is never gold: the answer lives in the cited book.
    var lead: String?
    var leadIsGold: Bool
    /// The lead each candidate rule in `leadRules` would choose.
    var leads: [String: String?]
    var terms: [String]
    var leadEvidence: [LeadEvidence]
    var passages: [PassageRecord]
    var seconds: Double
}

var questions = try loadQuestions(questionsPath)
if let only { questions = questions.filter { $0.id == only } }
if let limit { questions = Array(questions.prefix(limit)) }
var results: [QuestionResult] = []
struct PassageText: Encodable { var label: Int; var slug: String; var title: String; var keywords: [String]; var text: String }
var fieldGuideTexts: [String: [PassageText]] = [:]
var errors = 0
/// A run of these means kiwix-serve stopped answering mid-run.
var referenceSilent = 0
for q in questions {
    guard RetrievalCoordinator.shouldRetrieve(q.text) else { continue }
    let t0 = Date()
    var candidates: [Candidate] = []
    for r in coordinator.retrievers {
        for (i, p) in ((try? await r.retrieve(q.text, limit: coordinator.limitPerRetriever)) ?? []).enumerated() {
            candidates.append(Candidate(retriever: r.name, rank: i + 1, key: p.source.dedupeKey, title: p.source.title, score: p.score))
        }
    }
    let passages = await coordinator.retrieve(q.text)
    if passages.isEmpty { errors += 1 }
    var exact: Int?, book: Int?
    for p in passages {
        for t in q.targets {
            switch match(p, t) {
            case .exact: exact = min(exact ?? p.label, p.label); book = min(book ?? p.label, p.label)
            case .book: book = min(book ?? p.label, p.label)
            case .none: break
            }
        }
    }
    func covered(_ text: String) -> Int {
        let c = canonical(text)
        return q.gold.filter { fact in fact.keyGroups.allSatisfy { group in group.contains { c.contains($0) } } }.count
    }
    let articleText = passages.filter { p in q.targets.contains { match(p, $0) == .exact } }.map(\.text).joined(separator: "\n")
    let targets = q.targets.map { t -> String in
        switch t { case .article(let s): return "fieldguide:\(s)"; case .catalogue(let id, let title): return "\(id):\(title)" }
    }
    let lead = RetrievalCoordinator.fieldGuideLead(for: q.text, in: passages)
    let leadSlug = lead.map(slug(of:))
    let leadIsGold = lead.map { l in q.targets.contains { match(l, $0) == .exact } } ?? false
    let leads = Dictionary(uniqueKeysWithValues: leadRules.map { rule in (rule.name, RetrievalCoordinator.fieldGuideLead(for: q.text, in: passages, policy: rule.policy).map(slug(of:))) })
    let terms = RetrievalCoordinator.terms(in: q.text)
    fieldGuideTexts[q.id] = passages.filter { $0.retriever == RetrievalCoordinator.fieldGuideRetriever }.map { PassageText(label: $0.label, slug: slug(of: $0), title: $0.source.title, keywords: $0.keywords ?? [], text: $0.text) }
    let evidence = passages.filter { $0.retriever == RetrievalCoordinator.fieldGuideRetriever }.map { p in
        LeadEvidence(label: p.label, slug: slug(of: p), title: p.source.title, inText: FieldGuideProcedure.matched(in: p.text, terms: terms, stem: true),
                     inTitle: FieldGuideProcedure.matched(in: p.source.title, terms: terms, stem: true), inKeywords: FieldGuideProcedure.matched(in: (p.keywords ?? []).joined(separator: ". "), terms: terms, stem: true))
    }
    results.append(QuestionResult(id: q.id, coverage: q.coverage, question: q.text, candidates: candidates, targets: targets, targetInstalled: q.targets.contains(where: isInstalled),
                                  exactRank: exact, bookRank: book,
                                  goldFacts: q.gold.count, goldCovered: covered(passages.map(\.text).joined(separator: "\n")), goldCoveredByArticle: covered(articleText),
                                  lead: leadSlug, leadIsGold: leadIsGold, leads: leads, terms: terms, leadEvidence: evidence,
                                  passages: passages.map { PassageRecord(label: $0.label, retriever: $0.retriever, key: $0.source.dedupeKey, title: $0.source.title, chars: $0.text.count, score: $0.score) },
                                  seconds: Date().timeIntervalSince(t0)))
    if !passages.contains(where: { if case .zimArticle = $0.source { return true } else { return false } }) { referenceSilent += 1 }
    let mark = exact.map { "exact@\($0)" } ?? book.map { "book@\($0)" } ?? "miss"
    let leadMark = leadSlug.map { leadIsGold ? "  lead ok" : "  lead WRONG: \($0)" } ?? ""
    print("\(mark.padding(toLength: 8, withPad: " ", startingAt: 0)) \(q.coverage.padding(toLength: 10, withPad: " ", startingAt: 0)) \(q.id)  [\(passages.map { $0.retriever.prefix(3) }.joined(separator: " "))]\(leadMark)")
}

// MARK: Totals

struct Totals: Encodable {
    var questions: Int; var retrievedNothing: Int; var referenceSilent: Int; var kiwixState: String
    var fieldguideQuestions: Int; var fieldguideExact: Int; var fieldguideExactTop3: Int; var fieldguideAnyArticle: Int
    var catalogueQuestions: Int; var catalogueInstalled: Int; var catalogueBook: Int; var catalogueExact: Int
    var goldFacts: Int; var goldCovered: Int; var goldCoveredByArticle: Int
    /// Over the Field Guide questions: how many got a lead, how many of those leads are the gold article, the gold
    /// share of the leads (precision) and of the questions (recall). `leadOnCatalogue` counts leads on the other questions.
    var leadChosen: Int; var leadGold: Int; var leadPrecision: Double; var leadRecall: Double; var leadOnCatalogue: Int
    var passages: Int; var byRetriever: [String: Int]; var bySource: [String: Int]; var promptChars: [String: Int]
}

let fg = results.filter { $0.coverage == "fieldguide" }
let cat = results.filter { $0.coverage == "catalogue" }
let catInstalled = cat.filter(\.targetInstalled)
var byRetriever: [String: Int] = [:], bySource: [String: Int] = [:]
var charsPerQuestion: [Int] = []
for r in results {
    charsPerQuestion.append(r.passages.map(\.chars).reduce(0, +))
    for p in r.passages {
        byRetriever[p.retriever, default: 0] += 1
        let origin = p.key.hasPrefix("zim:") ? String(p.key.dropFirst(4).split(separator: "/").first ?? "") : p.key.split(separator: "#").first.map(String.init) ?? p.key
        bySource[origin, default: 0] += 1
    }
}
let sortedChars = charsPerQuestion.sorted()
let leadChosen = fg.filter { $0.lead != nil }.count, leadGold = fg.filter(\.leadIsGold).count
let totals = Totals(
    questions: results.count, retrievedNothing: errors, referenceSilent: referenceSilent, kiwixState: kiwix.processState.label,
    fieldguideQuestions: fg.count, fieldguideExact: fg.filter { $0.exactRank != nil }.count, fieldguideExactTop3: fg.filter { ($0.exactRank ?? 99) <= 3 }.count, fieldguideAnyArticle: fg.filter { $0.bookRank != nil }.count,
    catalogueQuestions: cat.count, catalogueInstalled: catInstalled.count, catalogueBook: catInstalled.filter { $0.bookRank != nil }.count, catalogueExact: catInstalled.filter { $0.exactRank != nil }.count,
    goldFacts: fg.map(\.goldFacts).reduce(0, +), goldCovered: fg.map(\.goldCovered).reduce(0, +), goldCoveredByArticle: fg.map(\.goldCoveredByArticle).reduce(0, +),
    leadChosen: leadChosen, leadGold: leadGold, leadPrecision: leadChosen == 0 ? 1 : Double(leadGold) / Double(leadChosen), leadRecall: fg.isEmpty ? 0 : Double(leadGold) / Double(fg.count),
    leadOnCatalogue: cat.filter { $0.lead != nil }.count,
    passages: byRetriever.values.reduce(0, +), byRetriever: byRetriever, bySource: bySource,
    promptChars: ["min": sortedChars.first ?? 0, "median": sortedChars.isEmpty ? 0 : sortedChars[sortedChars.count / 2], "max": sortedChars.last ?? 0])

func isGold(_ r: QuestionResult, _ slug: String?) -> Bool { slug.map { r.targets.contains("fieldguide:" + $0) } ?? false }
print("\nlead rules over the \(fg.count) field guide questions (chosen, gold, precision, recall) and leads on the \(cat.count) catalogue questions:")
for rule in leadRules {
    let chosen = fg.filter { $0.leads[rule.name] ?? nil != nil }.count, gold = fg.filter { isGold($0, $0.leads[rule.name] ?? nil) }.count
    let onCatalogue = cat.filter { $0.leads[rule.name] ?? nil != nil }.count
    print("  " + rule.name.padding(toLength: 42, withPad: " ", startingAt: 0) + String(format: " %3d %3d  %5.1f%%  %5.1f%%   catalogue %d", chosen, gold, chosen == 0 ? 100 : 100 * Double(gold) / Double(chosen), 100 * Double(gold) / Double(max(1, fg.count)), onCatalogue))
}
print("""

questions \(totals.questions), retrieved nothing \(totals.retrievedNothing), no ZIM passage \(totals.referenceSilent), kiwix-serve \(totals.kiwixState) at the end
field guide: exact article \(totals.fieldguideExact)/\(totals.fieldguideQuestions), in top 3 \(totals.fieldguideExactTop3), any field guide article \(totals.fieldguideAnyArticle)
catalogue:   cited book \(totals.catalogueBook)/\(totals.catalogueInstalled) installed (of \(totals.catalogueQuestions)), cited title \(totals.catalogueExact)
gold facts (field guide questions): \(totals.goldCovered)/\(totals.goldFacts) covered by the retrieved text, \(totals.goldCoveredByArticle) by the gold article's own passage
lead: chosen for \(totals.leadChosen) of \(totals.fieldguideQuestions) field guide questions, gold for \(totals.leadGold) (precision \(String(format: "%.1f", 100 * totals.leadPrecision))%, recall \(String(format: "%.1f", 100 * totals.leadRecall))%), \(totals.leadOnCatalogue) leads on catalogue questions
passages \(totals.passages): \(byRetriever.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
prompt chars min \(totals.promptChars["min"]!) median \(totals.promptChars["median"]!) max \(totals.promptChars["max"]!)
by source: \(bySource.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
""")

if let outPath {
    struct Report: Encodable { var created: String; var library: String; var totals: Totals; var questions: [QuestionResult] }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(Report(created: ISO8601DateFormatter().string(from: Date()), library: library.root.path, totals: totals, questions: results)).write(to: URL(fileURLWithPath: outPath))
    print("wrote \(outPath)")
}
if let textsPath {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(fieldGuideTexts).write(to: URL(fileURLWithPath: textsPath))
    print("wrote \(textsPath)")
}
if referenceSilent > 0 { print("kiwix-serve output tail:\n" + kiwix.recentOutput.split(separator: "\n").suffix(12).joined(separator: "\n")) }
kiwix.stop()
try? FileManager.default.removeItem(at: scratch)
