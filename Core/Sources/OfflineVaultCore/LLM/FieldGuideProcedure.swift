import Foundation

/// The human-written procedure of a Field Guide article as a retrieval passage. The renderer
/// (scripts/content/ovpub/fieldguide/render.py) emits the procedure under a "What to do" heading, then the keyword
/// line ("Also: …"), then each adapted source under its credit ("Adapted from …"). `HTMLText.extract` turns that
/// into one line per heading, step or caution.
public enum FieldGuideProcedure {
    /// Marks a run of steps left out of a trimmed procedure.
    public static let gap = "…"

    /// Everything before the keyword line or the first source credit, whichever comes first.
    static func humanWrittenPart(of article: String) -> Substring {
        let ends = ["\nAlso: ", "\nAdapted from "].compactMap { article.range(of: $0)?.lowerBound }
        guard let end = ends.min() else { return article[...] }
        return article[..<end]
    }

    /// The article's keyword line ("Also: burn, scald, …"), empty when it has none.
    public static func keywords(of article: String) -> [String] {
        guard let start = article.range(of: "\nAlso: ")?.upperBound else { return [] }
        let line = article[start...].prefix { $0 != "\n" }
        return line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The steps and cautions after "What to do", one per line; the whole human-written part when the heading is absent.
    public static func section(of article: String) -> String {
        let lines = humanWrittenPart(of: article).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard let heading = lines.firstIndex(of: "What to do") else { return lines.joined(separator: "\n") }
        return lines[(heading + 1)...].joined(separator: "\n")
    }

    /// How many of the query's terms the text contains, as whole words or as the stem of a longer word ("cord" in
    /// "cords", "contraction" in "contractions"); a short term must match a whole word so "car" is not "carry".
    public static func matchedTerms(in text: String, terms: [String]) -> Int { matched(in: text, terms: terms).count }

    /// The query terms the text contains, by the `matchedTerms` rule. With `stem`, a term and a word also match when
    /// they share a stem of four letters or more after one inflection is dropped ("burned" and "burns", "choking" and "choke").
    public static func matched(in text: String, terms: [String], stem: Bool = false) -> [String] {
        let words = Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        let stems = stem ? Set(words.map(Self.stem)) : []
        return terms.filter { term in
            if words.contains(term) || (term.count >= 4 && words.contains { $0.hasPrefix(term) }) { return true }
            guard stem else { return false }
            let s = Self.stem(term)
            return s.count >= 4 && (stems.contains(s) || stems.contains { $0.count >= 4 && ($0.hasPrefix(s) || s.hasPrefix($0)) })
        }
    }

    /// The word without one trailing "ing", "ed" or "s", when at least four letters remain.
    static func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "s"] where word.hasSuffix(suffix) && word.count - suffix.count >= 4 { return String(word.dropLast(suffix.count)) }
        return word
    }

    /// The procedure when it fits in `maxChars`, else the lines that match a query term and their neighbours, with
    /// `gap` where lines were left out. Over the cap, lines go in order of fewest matches, longest first, so the
    /// steps that answer the question survive and more of them fit. With no match at all, the start of the procedure.
    public static func trimmed(_ text: String, terms: [String], maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        let lines = text.split(separator: "\n").map(String.init)
        let scores = lines.map { matchedTerms(in: $0, terms: terms) }
        var kept = Set<Int>()
        for (i, s) in scores.enumerated() where s > 0 { for j in max(0, i - 1)...min(lines.count - 1, i + 1) { kept.insert(j) } }
        if kept.isEmpty {
            var prefix = ""
            for line in lines where prefix.count + line.count + 1 <= maxChars - 1 { prefix += (prefix.isEmpty ? "" : "\n") + line }
            return prefix + "\n" + gap
        }
        var dropOrder = kept.sorted { scores[$0] != scores[$1] ? scores[$0] < scores[$1] : lines[$0].count > lines[$1].count }
        func render(_ kept: Set<Int>) -> String {
            var out: [String] = []
            var previous: Int?
            for i in kept.sorted() {
                if let p = previous, i != p + 1 { out.append(gap) }
                out.append(lines[i]); previous = i
            }
            return out.joined(separator: "\n")
        }
        var out = render(kept)
        var dropped: [Int] = []
        while out.count > maxChars, kept.count > 1 { dropped.append(dropOrder.removeFirst()); kept.remove(dropped.last!); out = render(kept) }
        // Dropping a long step can leave room for the shorter ones dropped before it; most matches first.
        for i in dropped.reversed() where render(kept.union([i])).count <= maxChars { kept.insert(i); out = render(kept) }
        return out.count > maxChars ? String(out.prefix(maxChars - 1)) + gap : out
    }

    /// Splits `budget` between passages in proportion to `weights`; a passage shorter than its share hands the rest on.
    public static func shares(lengths: [Int], weights: [Int], budget: Int) -> [Int] {
        var shares = Array(repeating: 0, count: lengths.count)
        var open = Set(lengths.indices)
        var remaining = budget
        while !open.isEmpty, remaining > 0 {
            let total = max(1, open.reduce(0) { $0 + weights[$1] })
            let fits = open.filter { lengths[$0] <= remaining * weights[$0] / total }
            if fits.isEmpty { for i in open { shares[i] = remaining * weights[i] / total }; break }
            for i in fits { shares[i] = lengths[i]; remaining -= lengths[i]; open.remove(i) }
        }
        return shares
    }

    /// Passage text for each procedure, nil where the procedure matches no query term. The matching ones share
    /// `budget` chars in proportion to the terms they match, each capped at `maxChars`, and are trimmed to their share.
    public static func passages(_ procedures: [String], terms: [String], maxChars: Int, budget: Int) -> [String?] {
        let weights = procedures.map { matchedTerms(in: $0, terms: terms) }
        let matched = procedures.indices.filter { weights[$0] > 0 }
        let allotted = shares(lengths: matched.map { min(procedures[$0].count, maxChars) }, weights: matched.map { weights[$0] }, budget: budget)
        var out: [String?] = Array(repeating: nil, count: procedures.count)
        for (k, i) in matched.enumerated() { out[i] = trimmed(procedures[i], terms: terms, maxChars: allotted[k]) }
        return out
    }
}
