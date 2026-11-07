import Foundation

/// Builds the grounded prompt and parses citations out of answers.
public enum Prompting {
    /// Shared framing: the user may be off-grid with no help available, so deflecting is not an answer.
    static let productContext = """
    You are OfflineVault, an assistant for people who may be off-grid, in an emergency, or otherwise without internet, phone signal, emergency services or professionals to call. Your job is to give practical, concrete, step-by-step guidance they can act on right now with what they have. Never make "see a professional" or "I can't help" the whole answer: give the best field guidance first, then add one short line on when and how to get professional care if it becomes possible. Stay calm and direct; use numbered steps for procedures; mention warning signs that mean the situation is getting worse.
    """

    public static let systemPrompt = productContext + """

    Library search is ON. Numbered SOURCES from the user's offline library are provided with each question. Rules:
    - Sources are retrieved automatically by keyword search and may be unrelated to the message. Use only sources that actually answer the question; silently ignore unrelated ones. Never summarise or repeat a source that was not asked about.
    - If the message is a greeting, thanks or small talk, reply in one short friendly sentence with no sources and no citations.
    - Base factual claims on the sources and cite them inline with square brackets like [1] or [2][3] right after each claim they support.
    - Make one claim per sentence with its [n] right after it, and keep the source's own wording and numbers for each cited claim instead of paraphrasing, so the app can show the matching quote from the source. Do not add a list of sources at the end; the app shows them.
    - If the sources answer only part of the question, answer that part with citations. For the rest, still give your best practical guidance, prefixed with "Unverified:" so the user knows it did not come from their library.
    - If no source is relevant, say "I couldn't find this in your library." in the first sentence, then give your best practical guidance anyway, prefixed with "Unverified:".
    - Never invent a source number that is not listed. Never present unverified content as if it came from the library.
    - A source marked "human-checked field guide" is a procedure a person checked against the manuals. When it is also marked "shown to the user above your answer", it is already on screen word for word: do not restate its steps. Add only what the other sources contribute, such as warning signs, what to do afterwards or a detail the procedure leaves out, and refer to its steps by number.
    - Never give a measurement, distance, time or dose that is not in a source. If no source gives one, say that instead of estimating.
    - For medical, electrical, structural or other safety-critical topics, after your steps remind the user to read the cited source text itself, because it is more reliable than your summary.
    - Prefer short paragraphs and numbered steps. Use metric units unless the source uses others.
    """

    /// Used when the "Search library" toggle is off: no sources, answer from general knowledge but still concretely.
    public static let generalSystemPrompt = productContext + """

    Library search is OFF, so you are answering from your own general knowledge and have not checked the user's reference library. Answer the question fully and concretely anyway. Do not invent citations or claim to have checked sources. If the topic is medical, electrical, structural or otherwise safety-critical, end with one line suggesting they turn on "Search library" to compare your answer against their reference books.
    """

    /// Used for greetings and small talk: no grounding scaffold, so even small models reply naturally.
    public static let casualSystemPrompt = """
    You are OfflineVault, a friendly assistant that runs offline on the user's Mac and can answer questions from their local library of reference articles, saved pages and videos. The user is making small talk. Reply in one or two short, natural sentences. Do not mention sources, citations or headings.
    """

    /// `leading` is the label of the Field Guide passage the transcript shows before the answer, so the model is told not to repeat it.
    public static func sourcesBlock(_ passages: [RetrievedPassage], leading: Int? = nil) -> String {
        if passages.isEmpty { return "SOURCES: none matched in the library. Start with \"I couldn't find this in your library.\" then give your best practical guidance, prefixed with \"Unverified:\"." }
        var s = "SOURCES:\n"
        for p in passages {
            var kind: String
            switch p.source {
            case .zimArticle(let book, _, _):
                kind = p.retriever == RetrievalCoordinator.fieldGuideRetriever ? "human-checked field guide procedure in \(book)" : "reference article in \(book)"
                if p.label == leading { kind += ", shown to the user above your answer" }
            case .page(_, _, let url): kind = "saved webpage \(url)"
            case .video(_, _, let start): kind = start.map { "video transcript at \(DurationFormat.string($0))" } ?? "video description"
            case .document(_, _, let page): kind = "document, page \(page)"
            }
            s += "\n[\(p.label)] \(p.source.title) (\(kind))\n\(p.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        }
        return s
    }

    /// Assembles the message list sent to the model: system prompt, trimmed history, then the user turn with its sources.
    public static func messages(history: [ChatMessage], userQuestion: String, passages: [RetrievedPassage], useLibrary: Bool = true, maxHistoryTurns: Int = 6, leading: Int? = nil) -> [(role: String, content: String)] {
        let smallTalk = passages.isEmpty && !RetrievalCoordinator.shouldRetrieve(userQuestion)
        let system = !useLibrary ? generalSystemPrompt : (smallTalk ? casualSystemPrompt : systemPrompt)
        var out: [(String, String)] = [("system", system)]
        let recent = history.filter { $0.role != .system && !$0.content.isEmpty }.suffix(maxHistoryTurns * 2)
        for m in recent {
            // Keep history compact: earlier user turns without their source dumps, answers as-is.
            out.append((m.role.rawValue, m.role == .user ? m.content : String(m.content.prefix(2000))))
        }
        out.append(("user", (smallTalk || !useLibrary) ? userQuestion : sourcesBlock(passages, leading: leading) + "\n\nQUESTION: " + userQuestion))
        return out.map { (role: $0.0, content: $0.1) }
    }

    /// Finds every [n] (and [n, m] / [n][m]) citation in order of first appearance.
    public static func citedLabels(in answer: String) -> [Int] {
        var result: [Int] = []
        let re = try! NSRegularExpression(pattern: "\\[(\\d{1,2}(?:\\s*,\\s*\\d{1,2})*)\\]", options: [])
        for m in re.matches(in: answer, range: NSRange(answer.startIndex..., in: answer)) {
            guard let r = Range(m.range(at: 1), in: answer) else { continue }
            for n in answer[r].split(separator: ",").compactMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) where !result.contains(n) { result.append(n) }
        }
        return result
    }

    /// Returns the passages the answer actually cites, in citation order, followed by none of the uncited ones.
    public static func citedPassages(answer: String, passages: [RetrievedPassage]) -> [RetrievedPassage] {
        let labels = citedLabels(in: answer)
        return labels.compactMap { l in passages.first { $0.label == l } }
    }

    /// Questions where a wrong answer kills: the model must not answer these from memory. With library search on and
    /// no source found, or with search off, the app replies with a fixed refusal instead of calling the model.
    public enum HighStakes: String, Sendable {
        case plantIdentification, mushroomIdentification, medicationDosing, chemicalMixing
        public var title: String {
            switch self {
            case .plantIdentification: return "plant identification"
            case .mushroomIdentification: return "mushroom identification"
            case .medicationDosing: return "medication dosing"
            case .chemicalMixing: return "chemical mixing"
            }
        }
    }

    public static func highStakes(_ question: String) -> HighStakes? {
        let q = question.lowercased()
        let asksIdentity = ["is this", "is it safe", "can i eat", "edible", "identify", "what plant", "which plant", "what mushroom", "which mushroom", "poisonous", "safe to eat", "look like", "looks like", "tell if"].contains { q.contains($0) }
        if (q.contains("mushroom") || q.contains("fungus") || q.contains("fungi") || q.contains("toadstool")) && asksIdentity { return .mushroomIdentification }
        if (q.contains("plant") || q.contains("berry") || q.contains("berries") || q.contains("leaf") || q.contains("leaves") || q.contains("root") || q.contains("wild ") || q.contains("forag")) && asksIdentity { return .plantIdentification }
        // Whole words, so "heimlich" is not "ml" and a choking baby is not a dosing question.
        let words = Set(q.components(separatedBy: CharacterSet.alphanumerics.inverted))
        let drugWords = ["dose", "dosage", "doses", "mg", "milligram", "milligrams", "tablet", "tablets", "pill", "pills", "ml", "overdose"]
        let drugPhrases = ["how much", "how many", "per kg", "per pound"]
        let meds = ["ibuprofen", "acetaminophen", "paracetamol", "tylenol", "advil", "aspirin", "amoxicillin", "antibiotic", "doxycycline", "cipro", "penicillin", "insulin", "epinephrine", "benadryl", "diphenhydramine", "morphine", "codeine", "naloxone", "medication", "medicine", "drug", "prescription", "infant", "child", "baby", "pediatric", "fish antibiotic"]
        if (drugWords.contains(where: words.contains) || drugPhrases.contains(where: { q.contains($0) })) && meds.contains(where: { q.contains($0) }) { return .medicationDosing }
        let chems = ["bleach", "ammonia", "chlorine", "pool shock", "calcium hypochlorite", "iodine", "hydrogen peroxide", "lye", "sodium hydroxide", "acid", "fuel", "gasoline", "propane"]
        let mixing = ["mix", "combine", "together", "ratio", "how much", "how many drops", "per gallon", "per litre", "per liter", "dilut"]
        if chems.contains(where: { q.contains($0) }) && mixing.contains(where: { q.contains($0) }) { return .chemicalMixing }
        return nil
    }

    /// Fixed reply used instead of the model when a high-stakes question has no library source behind it.
    public static func refusal(for category: HighStakes, libraryOn: Bool) -> String {
        let why = "A language model answers \(category.title) questions confidently even when it is wrong, and a wrong answer here can be fatal. OfflineVault only answers this kind of question from a source in your library that you can open and read."
        let next = libraryOn
            ? "Your library has no source for this yet. Add one (WikiMed, WikEM, an Army first-aid manual, a regional plant guide or the USDA/CDC documents) and ask again, or search the Library tab directly."
            : "Turn on **Search library** and ask again so the answer comes from a cited manual or reference article, or search the Library tab directly."
        return "I can't answer this from memory.\n\n\(why)\n\n\(next)"
    }

    /// The answer for a high-stakes question when the library does have sources: the passages themselves, each as one
    /// cited sentence so the transcript renders them as quotes, and nothing computed by the model. The first eval run
    /// showed the model happily stating "5 mL" for a two-year-old once a medicines book was in the library.
    public static func sourcesOnlyAnswer(for category: HighStakes, passages: [RetrievedPassage]) -> String {
        let lead: String
        switch category {
        case .medicationDosing:
            lead = "OfflineVault can't give a dose from memory: a confident wrong number here can be fatal. Use the dose on the packaging or leaflet, or ask a pharmacist, and compare it with what your library says."
        case .mushroomIdentification:
            lead = "OfflineVault can't identify a mushroom from memory and will not call one safe to eat. Do not eat it unless a field guide or an expert confirms it in person."
        case .plantIdentification:
            lead = "OfflineVault can't identify a plant from memory and will not call it edible. Do not eat it unless a plant guide or an expert confirms it in person."
        case .chemicalMixing:
            lead = "OfflineVault can't give a mix from memory. Never combine cleaning, fuel or pool products unless the label says so: the fumes or the mixture can be toxic or fatal."
        }
        var out = lead + " This is what your library says, word for word. Open each source and follow it, not a summary.\n"
        for p in passages {
            let text = p.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let excerpt = text.count > 320 ? String(text.prefix(320)).trimmingCharacters(in: .whitespaces) : text
            out += "\n\(p.source.title): \(excerpt) [\(p.label)]\n"
        }
        return out
    }

    /// Shown under the Field Guide block when it is the whole answer. The eval gate caught the model's commentary
    /// telling a hypertensive person with chest pain to stop their pills, right under the article saying never to;
    /// for safety-critical questions the human-checked procedure covers, the model is not consulted at all.
    public static let fieldGuideOnlyNote = "The Field Guide article above is the answer, checked by a person against the cited manuals. Ask a follow-up if your situation differs, and open the sources below for the manual text."

    /// Topics where the UI shows the "follow the source, not the summary" note.
    public static func isSafetyCritical(_ text: String) -> Bool {
        let keywords = ["tsunami", "earthquake", "tornado", "hurricane", "wildfire", "flood", "lightning", "avalanche", "blizzard", "heat stroke", "heatstroke", "hazmat", "chemical release", "radiation", "fallout", "evacuat", "medic", "pill", "tablet", "prescription", "blood pressure", "expired", "expiry", "inhaler", "epipen", "dose", "dosage", "bleed", "wound", "fracture", "cpr", "poison", "burn", "hypotherm", "infect", "antibiotic", "electric", "wiring", "voltage", "amper", "breaker", "solar", "battery", "generator", "structur", "load-bearing", "roof", "beam", "foundation", "gas", "propane", "carbon monoxide", "chlorine", "bleach", "purif", "pregnan", "infant", "allerg", "insulin", "seizure", "stroke", "heart attack", "chainsaw", "firearm"]
        let lower = text.lowercased()
        return keywords.contains { lower.contains($0) }
    }
}
