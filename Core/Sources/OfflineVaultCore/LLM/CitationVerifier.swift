import Foundation

/// Checks the model's `[n]` labels against the passages: when a cited sentence's words overlap far more with a
/// different passage, the label is corrected. Catches the common small-model slip of citing [1] for text that
/// came from [2]. Pure function, unit-tested.
public enum CitationVerifier {
    public struct Correction: Equatable, Sendable { public var from: Int; public var to: Int; public var sentence: String }

    public static func correct(answer: String, passages: [RetrievedPassage]) -> (text: String, corrections: [Correction]) {
        guard passages.count > 1 else { return (answer, []) }
        let bags: [Int: Set<String>] = Dictionary(uniqueKeysWithValues: passages.map { ($0.label, terms($0.text)) })
        var out = answer
        var corrections: [Correction] = []
        // Work sentence by sentence; a sentence ends at . ! ? or newline. Citations usually trail the sentence.
        let sentenceRe = try! NSRegularExpression(pattern: "[^.!?\\n]+[.!?]?(?:\\s*\\[\\d{1,2}(?:\\s*,\\s*\\d{1,2})*\\])+", options: [])
        let citeRe = try! NSRegularExpression(pattern: "\\[(\\d{1,2})\\]", options: [])
        var replacements: [(NSRange, String)] = []
        let ns = answer as NSString
        for m in sentenceRe.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
            let sentence = ns.substring(with: m.range)
            let body = citeRe.stringByReplacingMatches(in: sentence, range: NSRange(location: 0, length: (sentence as NSString).length), withTemplate: "")
            let words = terms(body)
            guard words.count >= 4 else { continue }
            let cites = citeRe.matches(in: sentence, range: NSRange(location: 0, length: (sentence as NSString).length)).compactMap { Int((sentence as NSString).substring(with: $0.range(at: 1))) }
            guard cites.count == 1, let cited = cites.first, let citedBag = bags[cited] else { continue } // only single, unambiguous citations are corrected
            let citedScore = overlap(words, citedBag)
            var best = (label: cited, score: citedScore)
            for (label, bag) in bags where label != cited {
                let s = overlap(words, bag)
                if s > best.score { best = (label, s) }
            }
            // Require a decisive margin: the better passage must explain at least 50% of the sentence's terms and
            // beat the cited one by a wide ratio.
            if best.label != cited, best.score >= 0.5, best.score >= citedScore * 2.0 + 0.15 {
                let fixed = sentence.replacingOccurrences(of: "[\(cited)]", with: "[\(best.label)]")
                replacements.append((m.range, fixed))
                corrections.append(Correction(from: cited, to: best.label, sentence: body.trimmingCharacters(in: .whitespaces)))
            }
        }
        for (range, fixed) in replacements.reversed() { out = (out as NSString).replacingCharacters(in: range, with: fixed) }
        return (out, corrections)
    }

    static let stop: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "is", "are", "be", "it", "this", "that", "as", "at", "by", "from", "not", "do", "if", "you", "your", "can", "will", "must", "should", "than", "then", "into", "over", "under", "about", "when", "where", "which", "who", "has", "have", "had", "was", "were", "its", "their", "they", "them", "there", "here", "also", "any", "all", "each", "may", "more", "most", "only", "other", "some", "such", "so", "no", "one", "two", "use", "used"]

    static func terms(_ s: String) -> Set<String> {
        Set(s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 && !stop.contains($0) }.map { String($0.prefix(6)) })
    }

    static func overlap(_ words: Set<String>, _ bag: Set<String>) -> Double {
        guard !words.isEmpty else { return 0 }
        return Double(words.intersection(bag).count) / Double(words.count)
    }
}
