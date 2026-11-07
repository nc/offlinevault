import XCTest
@testable import OfflineVaultCore

final class IndexAndRetrievalTests: XCTestCase {
    func testPageIndexingAndRanking() throws {
        let layout = try makeTempLibrary(self)
        let db = try IndexDatabase(url: layout.databaseURL)
        let pages = PageService(layout: layout, database: db)
        let a = URL(string: "https://a.example/boiling")!
        let b = URL(string: "https://b.example/filters")!
        try pages.index(id: PageService.pageId(for: a), url: a, title: "Boiling water safely", text: "Boiling water for one minute kills pathogens. Boiling is reliable. Boil longer at altitude.", fileName: "a.html", capturedAt: Date())
        try pages.index(id: PageService.pageId(for: b), url: b, title: "Choosing a filter", text: "Filters remove protozoa from water. Some mention boiling water once. Filters do not remove viruses.", fileName: "b.html", capturedAt: Date())
        let hits = try pages.search("boiling water")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.first?.page.title, "Boiling water safely", "document with the term in title and body ranks first")
        XCTAssertGreaterThan(hits[0].score, hits[1].score)
        XCTAssertTrue(hits[0].snippet.contains("«"), "snippet highlights matches")
        XCTAssertEqual(try pages.search("viruses").first?.page.title, "Choosing a filter")
        XCTAssertTrue(try pages.search("zzzz nothing").isEmpty)
        XCTAssertEqual(try pages.search("filt").first?.page.title, "Choosing a filter", "prefix match on last token")

        // Re-indexing replaces chunks rather than duplicating them.
        try pages.index(id: PageService.pageId(for: a), url: a, title: "Boiling water safely", text: "Updated text about boiling.", fileName: "a.html", capturedAt: Date())
        let count = try db.db.scalar("SELECT COUNT(*) FROM page_chunks WHERE page_id = ?", [.text(PageService.pageId(for: a))])
        XCTAssertEqual(count, .integer(1))
    }

    func testVideoTranscriptIndexingAndSearchWithTimestamps() throws {
        let layout = try makeTempLibrary(self)
        let db = try IndexDatabase(url: layout.databaseURL)
        let videos = VideoLibraryService(layout: layout, database: db)
        try Data("fake".utf8).write(to: layout.videos.appendingPathComponent("v1.mp4"))
        try Fixtures.string("sample.vtt").write(to: layout.videos.appendingPathComponent("v1.en.vtt"), atomically: true, encoding: .utf8)
        let sidecar = VideoSidecar(id: "v1", title: "Water purification basics", channel: "Field Channel", durationSeconds: 90, uploadDate: "20260101", description: "How to purify water", webpageURL: nil, quality: "480p", fileName: "v1.mp4", thumbnailFile: nil, subtitleFile: "v1.en.vtt", downloadedAt: Date(), sourceURL: nil)
        try videos.importSidecar(sidecar)
        let v = try XCTUnwrap(try videos.video(id: "v1"))
        XCTAssertEqual(v.status, .downloaded)
        XCTAssertEqual(try videos.transcript(for: "v1").count, 3)

        let hits = try videos.searchTranscripts("bleach")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].startSeconds, 45.0, "hit carries the timestamp of its window")
        XCTAssertEqual(try videos.searchMetadata("purification").first?.video.id, "v1")
        XCTAssertEqual(try videos.search("filter viruses").map(\.id), ["v1"])

        // Rescan is idempotent.
        XCTAssertEqual(try videos.rescanFolder(), 0)
        try videos.deleteDownloadedFiles(v, keepCatalogueEntry: true)
        XCTAssertEqual(try videos.video(id: "v1")?.status, .indexed)
        XCTAssertTrue(try videos.searchTranscripts("bleach").isEmpty)
    }

    func testIndexRecordsFlatPlaylistEntries() throws {
        let layout = try makeTempLibrary(self)
        let db = try IndexDatabase(url: layout.databaseURL)
        let videos = VideoLibraryService(layout: layout, database: db)
        let src = try videos.addSource(url: "https://www.youtube.com/playlist?list=PLbpi6ZahtOH6Blw3RGYpWkSByi_T7Rygb")
        XCTAssertEqual(src.kind, .playlist)
        let info = try YtDlpInfo.parse(Fixtures.data("ytdlp_playlist_flat.json"))
        XCTAssertEqual(try videos.recordIndexResult(sourceId: src.id, info: info), 3)
        XCTAssertEqual(try videos.videos(status: .indexed, sourceId: src.id).count, 3)
        XCTAssertEqual(try videos.sources().first?.itemCount, 3)
        // Re-indexing does not duplicate.
        XCTAssertEqual(try videos.recordIndexResult(sourceId: src.id, info: info), 3)
        XCTAssertEqual(try videos.videos().count, 3)
        XCTAssertThrowsError(try videos.addSource(url: "not a url"))
    }

    func testRetrievalMergeNormalisesAcrossRetrieversAndDedupes() {
        let ref = [
            RetrievedPassage(source: .zimArticle(book: "fg", path: "A/Boil", title: "Boiling"), text: "boil text", score: 1.0, retriever: "reference"),
            RetrievedPassage(source: .zimArticle(book: "fg", path: "A/Filter", title: "Filters"), text: "filter text", score: 0.92, retriever: "reference"),
        ]
        let pages = [
            RetrievedPassage(source: .page(id: "p1", title: "Page", url: "u"), text: "page text", score: 7.5, retriever: "pages"),
            RetrievedPassage(source: .page(id: "p1", title: "Page", url: "u"), text: "dup", score: 3.0, retriever: "pages"),
        ]
        let videos = [RetrievedPassage(source: .video(id: "v", title: "Vid", startSeconds: 45), text: "vid", score: 2.0, retriever: "videos")]
        let merged = RetrievalCoordinator.merge([ref, pages, videos], finalLimit: 10, maxChars: 10_000)
        XCTAssertEqual(merged.count, 4, "duplicate page removed")
        XCTAssertEqual(merged.map(\.label), [1, 2, 3, 4], "labels are sequential")
        XCTAssertEqual(Set(merged.prefix(3).map(\.score)), [1.0], "top of each retriever normalises to 1.0")
        XCTAssertEqual(merged.last?.source.title, "Filters")
        let limited = RetrievalCoordinator.merge([ref, pages], finalLimit: 2, maxChars: 10_000)
        XCTAssertEqual(limited.count, 2)
    }

    func testRetrievalMergeReservedSlotsComeFirst() {
        let guide = [
            RetrievedPassage(source: .zimArticle(book: "fg", path: "A/burns.html", title: "Burns"), text: "burns", score: 3.0, retriever: "fieldguide"),
            RetrievedPassage(source: .zimArticle(book: "fg", path: "A/shock.html", title: "Shock"), text: "shock", score: 1.0, retriever: "fieldguide"),
            RetrievedPassage(source: .zimArticle(book: "fg", path: "A/cpr.html", title: "CPR"), text: "cpr", score: 0.5, retriever: "fieldguide"),
        ]
        let reference = [
            RetrievedPassage(source: .zimArticle(book: "wiki", path: "Burn", title: "Burn"), text: "wiki burn", score: 9.0, retriever: "reference"),
            RetrievedPassage(source: .zimArticle(book: "fg", path: "A/burns.html", title: "Burns"), text: "burns again", score: 8.0, retriever: "reference"),
        ]
        let docs = (1...4).map { RetrievedPassage(source: .document(id: "fm", title: "FM", page: $0), text: "page \($0)", score: Double(10 - $0), retriever: "documents") }
        let merged = RetrievalCoordinator.merge([docs, reference, guide], finalLimit: 6, maxChars: 10_000, reserved: ["fieldguide": 2])
        XCTAssertEqual(merged.prefix(2).map(\.source.title), ["Burns", "Shock"], "the Field Guide's two best hits lead even though the manual scores higher")
        XCTAssertEqual(merged.map(\.label), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(merged.filter { $0.source.title == "Burns" }.count, 1, "the same article found by the all-books search is not repeated")
        XCTAssertEqual(Set(merged[2...3].map(\.source.title)), ["Burn", "FM"], "after the reserved slots the normalised ranking resumes with each retriever's best")
        let unreserved = RetrievalCoordinator.merge([docs, reference, guide], finalLimit: 6, maxChars: 10_000)
        XCTAssertNotEqual(unreserved.prefix(2).map(\.source.title), ["Burns", "Shock"], "without a reservation the guide competes on normalised score")
        let tight = RetrievalCoordinator.merge([docs, guide], finalLimit: 1, maxChars: 10_000, reserved: ["fieldguide": 2])
        XCTAssertEqual(tight.map(\.source.title), ["Burns"], "a reservation never exceeds the final limit")
        let capped = RetrievalCoordinator.merge([docs, guide], finalLimit: 6, maxChars: 10_000, reserved: ["fieldguide": 3], perOrigin: 2, perRetriever: ["documents": 1])
        XCTAssertEqual(capped.map(\.source.title), ["Burns", "Shock", "CPR", "FM"], "reserved slots ignore the per-origin cap; the manual is held to one chunk")
    }

    func testFieldGuidePassageIsTheProcedureAndStopsBeforeTheAppendedSources() {
        // Shape produced by scripts/content/ovpub/fieldguide/render.py after HTMLText.extract: title, summary, procedure, keyword line, sources.
        let article = "Burns\n\nWhat to do for a burn.\n\nWhat to do\n\n1. Cool under running water for 20 minutes.\n\n2. Cover it.\n\nAlso: burn, scald\n\nFM 4-25.11 First Aid\n\nAdapted from FM 4-25.11 (2002), US Army. Public domain.\n\nBurns are caused by heat..."
        XCTAssertEqual(FieldGuideProcedure.section(of: article), "1. Cool under running water for 20 minutes.\n2. Cover it.")
        let noKeywords = "Burns\nWhat to do\n1. Cool it.\nAdapted from FM 4-25.11, US Army.\nSource text"
        XCTAssertEqual(FieldGuideProcedure.section(of: noKeywords), "1. Cool it.")
        XCTAssertEqual(FieldGuideProcedure.section(of: "Plain article\nwith no sources"), "Plain article\nwith no sources", "an article without the heading keeps its whole human-written part")
    }

    func testProcedureOverTheCapKeepsTheMatchingStepsAndTheirNeighbours() {
        let steps = ["1. Call for help first.", "2. Set up a clean surface and gather scissors and string.", "3. Stay calm.", "4. Slow the head down.",
                     "5. Support the shoulders.", "6. Dry and wrap the baby.", "7. The cord: there is no hurry. Tie it 15 to 20 cm from the navel.",
                     "8. The placenta delivers itself. Do not pull on the cord.", "9. Massage the uterus until it is hard.", "10. Breech: support the body, never pull."]
        let text = steps.joined(separator: "\n")
        let terms = RetrievalCoordinator.terms(in: "where do i cut the cord with the scissors")
        XCTAssertEqual(FieldGuideProcedure.trimmed(text, terms: terms, maxChars: 10_000), text, "a procedure that fits is untouched")
        let gap = FieldGuideProcedure.gap
        XCTAssertEqual(FieldGuideProcedure.trimmed(text, terms: terms, maxChars: 300), [steps[0], steps[1], steps[2], gap, steps[5], steps[6], steps[7], steps[8]].joined(separator: "\n"),
                       "the scissors step and the two cord steps with their neighbours, a gap where steps 4 and 5 were left out")
        let tight = FieldGuideProcedure.trimmed(text, terms: terms, maxChars: 200)
        XCTAssertEqual(tight, [steps[1], steps[2], gap, steps[6], steps[7]].joined(separator: "\n"), "the longest neighbours go first and the matching steps stay")
        XCTAssertLessThanOrEqual(tight.count, 200)
        let long = ["1. Call for help.", "2. The cord " + String(repeating: "x", count: 100), "3. Rest.", "4. The cord " + String(repeating: "y", count: 200), "5. Breathe."]
        XCTAssertEqual(FieldGuideProcedure.trimmed(long.joined(separator: "\n"), terms: ["cord"], maxChars: 180), [long[0], long[1], long[2], gap, long[4]].joined(separator: "\n"),
                       "dropping the long cord step makes room for the short neighbours dropped before it")
        XCTAssertEqual(FieldGuideProcedure.matchedTerms(in: "the cords were carried", terms: ["cord", "car"]), 1, "a stem matches a longer word, a short term only a whole word")
        XCTAssertEqual(FieldGuideProcedure.trimmed(text, terms: ["nothing"], maxChars: 60), "1. Call for help first.\n3. Stay calm.\n" + gap, "with no match the start of the procedure is kept")
    }

    func testFieldGuideHitsShareTheBudgetByMatchedTermsAndAnUnmatchedOneIsDropped() {
        let cord = (1...6).map { "\($0). The cord and the baby, step \($0) of the delivery." }.joined(separator: "\n")
        let feeding = (1...6).map { "\($0). Feed the baby every few hours, step \($0)." }.joined(separator: "\n")
        let grief = "1. Sit with them.\n2. Listen."
        let terms = RetrievalCoordinator.terms(in: "baby just came out, what do i do with the cord")
        let texts = FieldGuideProcedure.passages([feeding, cord, grief], terms: terms, maxChars: 3700, budget: 10_000)
        XCTAssertEqual(texts, [feeding, cord, nil], "under the budget each matching procedure is whole; the one matching nothing is dropped")
        let tight = FieldGuideProcedure.passages([feeding, cord, grief], terms: terms, maxChars: 3700, budget: 300)
        XCTAssertEqual(tight.map { $0?.count ?? 0 }.reduce(0, +) <= 300, true)
        XCTAssertGreaterThan(tight[1]!.count, tight[0]!.count, "the procedure matching two terms gets twice the share of the one matching one")
        XCTAssertEqual(FieldGuideProcedure.shares(lengths: [100, 2000, 2000], weights: [1, 1, 2], budget: 1000), [100, 300, 600], "a short passage hands its spare share to the others")
    }

    func testFieldGuideLeadNeedsATopicTermMostOfTheQuestionAndAClearWinner() {
        func p(_ label: Int, _ title: String, _ text: String, keywords: [String] = [], retriever: String = RetrievalCoordinator.fieldGuideRetriever) -> RetrievedPassage {
            RetrievedPassage(label: label, source: .zimArticle(book: "fg", path: "A/\(title).html", title: title), text: text, score: 1, retriever: retriever, keywords: keywords)
        }
        let query = "baby just came out in the car. what do i do with the cord and the afterbirth"
        let childbirth = p(2, "Emergency childbirth", "7. The cord: there is no hurry. Dry the baby. Keep the afterbirth for the midwife.", keywords: ["labour", "umbilical cord"])
        let feeding = p(1, "Feeding", "1. Feed the baby every few hours in the car, cord or no cord. Afterbirth is not a worry.")
        let manual = p(3, "FM", "The cord and the baby and the afterbirth, in the car.", retriever: "reference")
        XCTAssertEqual(RetrievalCoordinator.fieldGuideLead(for: query, in: [feeding, childbirth, manual])?.label, 2, "a title or keyword term outranks more terms in the text, and the manual is not a Field Guide passage")
        XCTAssertNil(RetrievalCoordinator.fieldGuideLead(for: query, in: [feeding, manual]), "terms in the text alone do not make a lead")
        XCTAssertNil(RetrievalCoordinator.fieldGuideLead(for: query, in: [p(1, "Cars", "the baby and the cord")]), "a title term with under 60% of the question's terms is not enough")
        let afterbirth = p(1, "Afterbirth", "the baby, the cord, the afterbirth")
        XCTAssertNil(RetrievalCoordinator.fieldGuideLead(for: query, in: [afterbirth, p(2, "Cord", "the baby, the cord, the car")]), "two passages that tie on topic terms and within two text terms leave no lead")
        XCTAssertEqual(RetrievalCoordinator.fieldGuideLead(for: query, in: [afterbirth, p(2, "Cord", "the cord came, the baby, the car, the afterbirth")])?.label, 2, "two terms clear of the other passage settles the tie")
        XCTAssertEqual(RetrievalCoordinator.fieldGuideLead(for: "burned my hand", in: [p(1, "Burns and scalds", "cool the burn, remove rings from the hand")])?.label, 1, "\"burned\" matches \"burns\" by stem")
        XCTAssertEqual(RetrievalCoordinator.fieldGuideLead(for: "cord", in: [p(1, "Cord", "cut the cord")])?.label, 1, "a one-term question needs that one term")
    }

    /// Real passages from the dev library (retrievaltool --texts): the lead is the gold article or nothing. Negative
    /// cases are the wrong leads that stopped release 1.0.5, plus two where the gold article was not retrieved.
    func testFieldGuideLeadOnRealPassagesIsTheGoldArticleOrNothing() throws {
        struct Passage: Decodable { var label: Int; var slug: String; var title: String; var keywords: [String]; var text: String }
        struct Case: Decodable { var id: String; var question: String; var gold: String?; var mustLead: Bool; var passages: [Passage] }
        let cases = try JSONDecoder().decode([Case].self, from: Fixtures.data("fieldguide_lead_cases.json"))
        XCTAssertEqual(cases.count, 9)
        for c in cases {
            let passages = c.passages.map { RetrievedPassage(label: $0.label, source: .zimArticle(book: "fieldguide_en_2026-10b", path: "A/\($0.slug).html", title: $0.title), text: $0.text, score: 1, retriever: RetrievalCoordinator.fieldGuideRetriever, keywords: $0.keywords) }
            let lead = RetrievalCoordinator.fieldGuideLead(for: c.question, in: passages).flatMap { l in c.passages.first { $0.label == l.label }?.slug }
            if c.mustLead {
                XCTAssertEqual(lead, c.gold, "\(c.id): the lead is the gold article")
            } else {
                XCTAssertTrue(lead == nil || lead == c.gold, "\(c.id): led with \(lead ?? "nothing"), gold is \(c.gold ?? "no Field Guide article")")
            }
        }
    }

    func testFieldGuideIsIdentifiedByArtefactId() {
        XCTAssertTrue(ZimBook(name: "fieldguide_en_2026-10b", artefactId: "zim-fieldguide-2026-10b", fileName: "fieldguide_en_2026-10b.zim").isFieldGuide)
        XCTAssertFalse(ZimBook(name: "fieldguide_en_2026-10b", artefactId: nil, fileName: "fieldguide_en_2026-10b.zim").isFieldGuide, "a sideloaded file with no catalogue id is not the curated guide")
        XCTAssertFalse(ZimBook(name: "wikem", artefactId: "zim-wikem-2026-07", fileName: "wikem.zim").isFieldGuide)
    }

    func testPromptBuildingAndCitationParsing() {
        let passages = [
            RetrievedPassage(label: 1, source: .zimArticle(book: "fg", path: "A/Boil", title: "Boiling"), text: "Boil for one minute.", score: 1, retriever: "reference"),
            RetrievedPassage(label: 2, source: .video(id: "v", title: "Vid", startSeconds: 45), text: "[0:45] use bleach", score: 1, retriever: "videos"),
        ]
        let msgs = Prompting.messages(history: [ChatMessage(role: .user, content: "earlier"), ChatMessage(role: .assistant, content: "earlier answer")], userQuestion: "How long do I boil?", passages: passages)
        XCTAssertEqual(msgs.first?.role, "system")
        XCTAssertEqual(msgs.count, 4)
        XCTAssertTrue(msgs.last!.content.contains("[1] Boiling (reference article in fg)"))
        XCTAssertTrue(msgs.last!.content.contains("video transcript at 0:45"))
        XCTAssertTrue(msgs.last!.content.hasSuffix("QUESTION: How long do I boil?"))
        let guide = RetrievedPassage(label: 3, source: .zimArticle(book: "fieldguide", path: "A/boil.html", title: "Boil"), text: "1. Boil for one minute.", score: 1, retriever: RetrievalCoordinator.fieldGuideRetriever)
        XCTAssertTrue(Prompting.sourcesBlock(passages + [guide]).contains("[3] Boil (human-checked field guide procedure in fieldguide)\n"))
        XCTAssertTrue(Prompting.sourcesBlock(passages + [guide], leading: 3).contains("[3] Boil (human-checked field guide procedure in fieldguide, shown to the user above your answer)\n"))
        XCTAssertTrue(Prompting.messages(history: [], userQuestion: "How long do I boil?", passages: passages + [guide], leading: 3).last!.content.contains("shown to the user above your answer"))
        XCTAssertTrue(Prompting.systemPrompt.contains("do not restate its steps"))
        XCTAssertEqual(Prompting.citedLabels(in: "Boil it [1]. Or bleach [2][1]. Also [2, 3] and [99]."), [1, 2, 3, 99])
        XCTAssertEqual(Prompting.citedPassages(answer: "Use bleach [2] then boil [1].", passages: passages).map(\.label), [2, 1])
        XCTAssertTrue(Prompting.sourcesBlock([]).contains("SOURCES: none"))
        let casual = Prompting.messages(history: [], userQuestion: "hey there", passages: [])
        XCTAssertEqual(casual.first?.content, Prompting.casualSystemPrompt)
        XCTAssertEqual(casual.last?.content, "hey there", "small talk is sent without the grounding scaffold")
        let off = Prompting.messages(history: [], userQuestion: "how do I fix a carburettor", passages: [], useLibrary: false)
        XCTAssertEqual(off.first?.content, Prompting.generalSystemPrompt)
        XCTAssertEqual(off.last?.content, "how do I fix a carburettor", "library off: no SOURCES block")
        let unanswered = Prompting.messages(history: [], userQuestion: "how do I fix a carburettor", passages: [])
        XCTAssertEqual(unanswered.first?.content, Prompting.systemPrompt)
        XCTAssertTrue(unanswered.last!.content.contains("SOURCES: none"))
        XCTAssertTrue(Prompting.isSafetyCritical("How much bleach per litre?"))
        XCTAssertFalse(Prompting.isSafetyCritical("Who painted the Mona Lisa?"))
    }

    func testSmallTalkSkipsRetrieval() async {
        XCTAssertFalse(RetrievalCoordinator.shouldRetrieve("hey there"))
        XCTAssertFalse(RetrievalCoordinator.shouldRetrieve("Hello! Thanks :)"))
        XCTAssertTrue(RetrievalCoordinator.shouldRetrieve("how do I purify water"))
        XCTAssertEqual(RetrievalCoordinator.terms(in: "How many drops of bleach per litre?"), ["drops", "bleach", "per", "litre"])
        struct Loud: Retriever { let name = "loud"; func retrieve(_ q: String, limit: Int) async throws -> [RetrievedPassage] { [RetrievedPassage(source: .page(id: "p", title: "P", url: "u"), text: "noise", score: 1, retriever: name)] } }
        let c = RetrievalCoordinator(retrievers: [Loud()])
        let none = await c.retrieve("hey there")
        XCTAssertTrue(none.isEmpty, "no retriever is consulted for small talk")
        let some = await c.retrieve("purify water")
        XCTAssertEqual(some.count, 1)
    }

    func testThinkingFilterStripsSplitTags() {
        var f = ThinkingFilter()
        var out = f.feed("<thi"); out += f.feed("nk>secret reasoning</th"); out += f.feed("ink>Visible answer"); out += f.flush()
        XCTAssertEqual(out, "Visible answer")
        var g = ThinkingFilter()
        XCTAssertEqual(g.feed("plain text") + g.flush(), "plain text")
    }

    func testChatStorePersistsSources() throws {
        let db = try IndexDatabase.inMemory()
        let store = ChatStore(database: db)
        let c = try store.create(title: "Test", model: "m")
        var m = ChatMessage(role: .assistant, content: "Answer [1]", usedLibrary: false, leadingPassageLabel: 1)
        m.sources = [RetrievedPassage(label: 1, source: .page(id: "p", title: "P", url: "u"), text: "t", score: 1, retriever: "pages")]
        try store.save(ChatMessage(role: .user, content: "Q"), in: c.id)
        try store.save(m, in: c.id)
        let loaded = try store.messages(in: c.id)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first { $0.role == .assistant }?.sources.first?.source, .page(id: "p", title: "P", url: "u"))
        XCTAssertEqual(loaded.first { $0.role == .assistant }?.usedLibrary, false)
        XCTAssertEqual(loaded.first { $0.role == .assistant }?.leadingPassage?.text, "t", "the passage shown first survives a reload")
        XCTAssertNil(loaded.first { $0.role == .user }?.leadingPassageLabel)
        XCTAssertEqual(loaded.first { $0.role == .user }?.usedLibrary, true)
        try store.delete(c.id)
        XCTAssertTrue(try store.conversations().isEmpty)
    }

    func testFTSQueryEscaping() {
        XCTAssertEqual(FTSQuery.build("boiling water"), "\"boiling\" \"water\"*")
        XCTAssertEqual(FTSQuery.build("it's \"quoted\" AND stuff", prefixLast: false), "\"it\" \"s\" \"quoted\" \"and\" \"stuff\"")
        XCTAssertNil(FTSQuery.build("   "))
    }
}
