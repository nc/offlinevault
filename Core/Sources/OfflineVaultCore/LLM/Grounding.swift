import Foundation

/// A verbatim span of a retrieved passage that supports one cited sentence of an answer.
public struct Quote: Codable, Equatable, Hashable, Sendable {
    public var label: Int
    /// Exact substring of the passage's text: one to three of its sentences, never the model's words.
    public var text: String
    /// UTF-16 offsets of `text` in `RetrievedPassage.text`.
    public var range: Range<Int>
    /// 0...1, the share of the claim's terms found in the quote.
    public var score: Double
    public init(label: Int, text: String, range: Range<Int>, score: Double) { self.label = label; self.text = text; self.range = range; self.score = score }
}

public enum AnswerSegment: Equatable, Sendable {
    case prose(String)
    case claim(text: String, quotes: [Quote])
    case unverified(text: String, citedLabels: [Int])
}

public struct GroundedAnswer: Equatable, Sendable {
    public var segments: [AnswerSegment]
    public var supportedClaims: Int
    public var unverifiedClaims: Int
}

/// Turns a cited answer into prose, quoted claims and unverified claims. Pure and deterministic: the result can be
/// recomputed from a stored message and its passages at any time.
public enum Grounding {
    public static let threshold = 0.45

    public static func ground(answer: String, passages: [RetrievedPassage]) -> GroundedAnswer {
        let byLabel = Dictionary(passages.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        var segments: [AnswerSegment] = []
        var prose = ""
        func flushProse() { if !prose.isEmpty { segments.append(.prose(prose)); prose = "" } }
        for unit in units(in: answer) {
            let labels = citedLabels(in: unit)
            let text = claimText(unit)
            let flagged = text.hasPrefix("Unverified:")
            if labels.isEmpty && !flagged { prose += unit; continue }
            prose += unit.prefix { $0.isWhitespace }
            flushProse()
            if flagged {
                segments.append(.unverified(text: text, citedLabels: []))
            } else {
                let quotes = labels.compactMap { byLabel[$0].flatMap { bestQuote(for: text, in: $0) } }
                segments.append(quotes.isEmpty ? .unverified(text: text, citedLabels: labels) : .claim(text: text, quotes: quotes))
            }
            if unit.hasSuffix("\n") { prose += "\n" }
        }
        flushProse()
        let supported = segments.filter { if case .claim = $0 { return true }; return false }.count
        let unverified = segments.filter { if case .unverified = $0 { return true }; return false }.count
        return GroundedAnswer(segments: segments, supportedClaims: supported, unverifiedClaims: unverified)
    }

    // MARK: Sentences

    static let citation = "\\[\\d{1,2}(?:\\s*,\\s*\\d{1,2})*\\]"
    /// A sentence ends at a newline, or at . ! ? followed by whitespace, a citation or the end of the text, so decimals
    /// like 0.5 stay intact; citations trailing the sentence, before or after its full stop, belong to it.
    static let sentenceRe = try! NSRegularExpression(pattern: "(?:[^.!?\\n\\[]|[.!?](?![\\s\\[]|$)|\\[(?!\\d{1,2}(?:\\s*,\\s*\\d{1,2})*\\]))+[.!?]*(?:\\s*,?\\s*\(citation))*[.!?]*\\n?|\\n")
    static let citationRe = try! NSRegularExpression(pattern: "\\s*,?\\s*\(citation)")
    static let numberRe = try! NSRegularExpression(pattern: "\\d[\\d,]*(?:\\.\\d+)?")
    static let listMarkerRe = try! NSRegularExpression(pattern: "^\\s*(?:[-*•]|\\d{1,2}[.)]|\\**step \\d{1,2}:?\\**)\\s*", options: [.caseInsensitive])

    /// Sentence units covering the whole string in order, so joining them gives the string back.
    static func units(in s: String) -> [String] {
        let ns = s as NSString
        var out: [String] = []
        var cursor = 0
        for m in sentenceRe.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor { out.append(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))) }
            out.append(ns.substring(with: m.range))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { out.append(ns.substring(from: cursor)) }
        return out
    }

    static func citedLabels(in unit: String) -> [Int] {
        var labels: [Int] = []
        for m in citationRe.matches(in: unit, range: NSRange(unit.startIndex..., in: unit)) {
            guard let r = Range(m.range, in: unit) else { continue }
            for n in unit[r].components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init) where !labels.contains(n) { labels.append(n) }
        }
        return labels
    }

    static func claimText(_ unit: String) -> String {
        citationRe.stringByReplacingMatches(in: unit, range: NSRange(unit.startIndex..., in: unit), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Matching

    /// The best window of one to three consecutive passage sentences, when it reaches the threshold. A window must
    /// contain every number the claim states and at least three of its terms (all of them for a shorter claim), so two
    /// topic words such as "severe hypothermia" cannot verify a claim on their own. A longer window wins only when
    /// each extra sentence brings more than one and a half matched terms, so a stray common word does not stretch
    /// the quote.
    static func bestQuote(for claim: String, in passage: RetrievedPassage) -> Quote? {
        let body = listMarkerRe.stringByReplacingMatches(in: claim, range: NSRange(claim.startIndex..., in: claim), withTemplate: "")
        let claimTerms = CitationVerifier.terms(body)
        let claimNumbers = numbers(in: body)
        guard !claimTerms.isEmpty else { return nil }
        let ns = passage.text as NSString
        let sentences = sentenceRanges(in: passage.text)
        var best: (quote: Quote, matched: Int, rank: Double)?
        for size in 1...3 {
            guard sentences.count >= size else { break }
            for i in 0...(sentences.count - size) {
                let range = NSRange(location: sentences[i].location, length: sentences[i + size - 1].location + sentences[i + size - 1].length - sentences[i].location)
                let window = ns.substring(with: range)
                guard claimNumbers.isSubset(of: numbers(in: window)) else { continue }
                let matched = claimTerms.intersection(CitationVerifier.terms(window)).count
                let rank = Double(matched) - 1.5 * Double(size - 1)
                if rank > (best?.rank ?? 0) {
                    best = (Quote(label: passage.label, text: window, range: range.location..<(range.location + range.length), score: Double(matched) / Double(claimTerms.count)), matched, rank)
                }
            }
        }
        guard let best, best.quote.score >= threshold, best.matched >= min(3, claimTerms.count) else { return nil }
        return best.quote
    }

    /// Numbers as the reader compares them: thousands separators dropped, units ignored, "0.5" kept as a decimal.
    static func numbers(in s: String) -> Set<String> {
        Set(numberRe.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s) }.map { s[$0].replacingOccurrences(of: ",", with: "").trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
    }

    /// UTF-16 ranges of the passage's sentences with surrounding whitespace trimmed, so a quote never starts or ends
    /// on a space or newline. Extracted article and PDF text wraps long lines mid-sentence; a line that ends without
    /// punctuation continues into the next one when that line is long, or when the next line carries on in lowercase
    /// or with a digit ("Add 2 drops\nper litre"), so a quote never starts or stops mid-sentence.
    static func sentenceRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        let ws = CharacterSet.whitespacesAndNewlines
        let all = units(in: text)
        var ranges: [NSRange] = []
        var start = 0
        var wrapped = false
        for (i, unit) in all.enumerated() {
            var lo = start, hi = start + (unit as NSString).length
            start = hi
            while lo < hi, let u = Unicode.Scalar(ns.character(at: lo)), ws.contains(u) { lo += 1 }
            while hi > lo, let u = Unicode.Scalar(ns.character(at: hi - 1)), ws.contains(u) { hi -= 1 }
            guard hi > lo else { continue }
            if wrapped, let last = ranges.last { ranges[ranges.count - 1] = NSRange(location: last.location, length: hi - last.location) }
            else { ranges.append(NSRange(location: lo, length: hi - lo)) }
            let endsLine = unit.hasSuffix("\n"), punctuated = ".!?:".utf16.contains(ns.character(at: hi - 1))
            wrapped = endsLine && !punctuated && (hi - lo >= 40 || continuesInLowercase(all, after: i))
        }
        return ranges
    }

    /// True when the next non-empty unit starts with a lowercase letter or a digit, which only a wrapped sentence does.
    static func continuesInLowercase(_ units: [String], after i: Int) -> Bool {
        for u in units[(i + 1)...] {
            guard let first = u.unicodeScalars.first(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) else { continue }
            return CharacterSet.lowercaseLetters.contains(first) || CharacterSet.decimalDigits.contains(first)
        }
        return false
    }
}
