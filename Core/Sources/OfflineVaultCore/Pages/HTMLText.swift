import Foundation

/// Readable-text extraction from HTML (for FTS indexing and retrieval passages).
public enum HTMLText {
    public struct Extraction: Equatable, Sendable {
        public var title: String
        public var body: String
        public var excerpt: String { String(body.prefix(240)).replacingOccurrences(of: "\n", with: " ") }
    }

    static let blockElements: Set<String> = ["p", "div", "br", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "tr", "td", "th", "table", "section", "article", "header", "footer", "blockquote", "pre", "figure", "figcaption", "dd", "dt", "dl", "main", "nav", "aside", "hr", "address", "details", "summary"]
    static let skipElements: Set<String> = ["script", "style", "noscript", "template", "svg", "iframe", "head", "nav", "footer", "aside", "form", "button", "select", "option", "canvas", "video", "audio", "picture"]

    /// Extracts title and readable body text. Prefers `<article>`/`<main>` content when it holds most of the page text.
    public static func extract(from html: String) -> Extraction {
        let tokens = HTMLTokenizer.tokenize(html)
        var title = ""
        var ogTitle: String?
        var h1: String?
        var full = ""
        var scoped = ""
        var scopedDepth = 0
        var inScoped = false
        var skipDepth = 0
        var skipStack: [String] = []
        var elementStack: [String] = []
        /// One entry per open list: the next item number for an ordered list, nil for a bulleted one.
        var listCounters: [Int?] = []

        func appendText(_ s: String) {
            full += s
            if inScoped { scoped += s }
        }

        for t in tokens {
            switch t {
            case .doctype, .comment: continue
            case .rawText(let el, let content):
                if el == "title" && title.isEmpty { title = collapse(decodeEntities(content)) }
            case .startTag(let name, let attrs, let selfClosing):
                if name == "meta", attrs.first(where: { $0.name == "property" && $0.value == "og:title" }) != nil, let c = attrs.first(where: { $0.name == "content" })?.value { ogTitle = collapse(c) }
                if skipElements.contains(name) && !selfClosing { skipStack.append(name); skipDepth += 1 }
                if skipDepth > 0 { continue }
                if (name == "article" || name == "main") && !inScoped { inScoped = true; scopedDepth = elementStack.count }
                if blockElements.contains(name) { appendText("\n") }
                if name == "ol" { listCounters.append(1) } else if name == "ul" { listCounters.append(nil) }
                if name == "li", let n = listCounters.last ?? nil { appendText("\(n). "); listCounters[listCounters.count - 1] = n + 1 }
                if name == "h1" { elementStack.append("h1!") } else if !selfClosing { elementStack.append(name) }
                if name == "img", let alt = attrs.first(where: { $0.name == "alt" })?.value, !alt.isEmpty { appendText(" ") }
            case .endTag(let name):
                if let last = skipStack.last, last == name { skipStack.removeLast(); skipDepth -= 1; continue }
                if skipDepth > 0 { continue }
                if let idx = elementStack.lastIndex(where: { $0 == name || ($0 == "h1!" && name == "h1") }) { elementStack.removeSubrange(idx...) }
                if blockElements.contains(name) { appendText("\n") }
                if name == "ol" || name == "ul", !listCounters.isEmpty { listCounters.removeLast() }
                if (name == "article" || name == "main") && inScoped && elementStack.count <= scopedDepth { inScoped = false; scopedDepth = 0; scoped += "\n" }
            case .text(let s):
                if skipDepth > 0 { continue }
                let decoded = decodeEntities(s)
                if elementStack.contains("h1!") && h1 == nil { let c = collapse(decoded); if !c.isEmpty { h1 = c } }
                appendText(decoded)
            }
        }
        let fullClean = normalise(full)
        let scopedClean = normalise(scoped)
        let body = (scopedClean.count >= 200 && Double(scopedClean.count) >= Double(fullClean.count) * 0.25) ? scopedClean : fullClean
        if title.isEmpty { title = ogTitle ?? h1 ?? "" }
        return Extraction(title: title, body: body)
    }

    static func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapses runs of spaces and more than one blank line.
    static func normalise(_ s: String) -> String {
        var lines: [String] = []
        for raw in s.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "[ \\t\\r\\f\\u00a0]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { if lines.last?.isEmpty == false { lines.append("") } } else { lines.append(line) }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    static let namedEntities: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00a0}", "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "deg": "°", "times": "×", "middot": "·", "bull": "•", "laquo": "«", "raquo": "»", "euro": "€", "pound": "£", "frac12": "½", "frac14": "¼", "frac34": "¾", "plusmn": "±", "para": "¶", "sect": "§"]

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let ent = String(s[s.index(after: i)..<semi])
                if ent.hasPrefix("#x") || ent.hasPrefix("#X"), let v = UInt32(ent.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { out.append(Character(u)); i = s.index(after: semi); continue }
                if ent.hasPrefix("#"), let v = UInt32(ent.dropFirst()), let u = Unicode.Scalar(v) { out.append(Character(u)); i = s.index(after: semi); continue }
                if let r = namedEntities[ent] { out += r; i = s.index(after: semi); continue }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    /// Splits text into retrieval chunks of roughly `targetChars`, breaking on paragraph boundaries.
    public static func chunk(_ text: String, targetChars: Int = 900, maxChars: Int = 1400) -> [String] {
        var chunks: [String] = []
        var current = ""
        for para in text.components(separatedBy: "\n") {
            let p = para.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            if current.isEmpty { current = p; continue }
            if current.count + p.count + 1 <= targetChars { current += "\n" + p; continue }
            chunks.append(current); current = p
        }
        if !current.isEmpty { chunks.append(current) }
        // Hard-split oversize chunks on sentence boundaries.
        var final: [String] = []
        for c in chunks {
            if c.count <= maxChars { final.append(c); continue }
            var piece = ""
            for sentence in c.split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" }) {
                let s = String(sentence).trimmingCharacters(in: .whitespaces) + "."
                if piece.count + s.count > maxChars, !piece.isEmpty { final.append(piece); piece = "" }
                piece += (piece.isEmpty ? "" : " ") + s
            }
            if !piece.isEmpty { final.append(piece) }
        }
        return final.filter { $0.count >= 20 }
    }

    /// Picks the window of `maxChars` from `text` containing the most query terms (for turning a whole article into a passage).
    public static func bestWindow(in text: String, queryTerms: [String], maxChars: Int = 900) -> String {
        guard text.count > maxChars else { return text }
        let terms = queryTerms.map { $0.lowercased() }.filter { $0.count >= 2 }
        let paragraphs = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !paragraphs.isEmpty, !terms.isEmpty else { return String(text.prefix(maxChars)) }
        var best = 0, bestScore = -1
        for (i, p) in paragraphs.enumerated() {
            let lower = p.lowercased()
            let score = terms.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) } * 10 + (lower.count > 80 ? 1 : 0)
            if score > bestScore { bestScore = score; best = i }
        }
        var out = paragraphs[best]
        var lo = best, hi = best
        while out.count < maxChars, lo > 0 || hi < paragraphs.count - 1 {
            if hi < paragraphs.count - 1 { hi += 1; out += "\n" + paragraphs[hi] }
            if out.count < maxChars, lo > 0 { lo -= 1; out = paragraphs[lo] + "\n" + out }
        }
        return out.count > maxChars ? String(out.prefix(maxChars)) + "…" : out
    }
}
