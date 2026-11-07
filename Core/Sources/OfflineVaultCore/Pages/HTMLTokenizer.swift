import Foundation

/// A small, forgiving HTML tokenizer — enough for rewriting documents (inlining assets, stripping scripts)
/// and extracting text. Not a full HTML5 parser; it never builds a tree, it streams tokens.
public enum HTMLToken: Equatable {
    public struct Attribute: Equatable { public var name: String; public var value: String?; public init(name: String, value: String?) { self.name = name; self.value = value } }
    case text(String)
    case startTag(name: String, attributes: [Attribute], selfClosing: Bool)
    case endTag(name: String)
    case comment(String)
    case doctype(String)
    /// Raw content of <script>/<style> etc. (between start and end tag).
    case rawText(element: String, content: String)
}

public struct HTMLTokenizer {
    static let rawTextElements: Set<String> = ["script", "style", "textarea", "title", "xmp", "noscript"]
    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]

    public static func tokenize(_ html: String) -> [HTMLToken] {
        var tokens: [HTMLToken] = []
        let s = Array(html.utf8)
        var i = 0
        let n = s.count
        var textStart = 0

        func flushText(_ end: Int) {
            if end > textStart { tokens.append(.text(String(decoding: s[textStart..<end], as: UTF8.self))) }
        }
        func starts(_ at: Int, _ lit: String) -> Bool {
            let l = Array(lit.utf8)
            guard at + l.count <= n else { return false }
            for k in 0..<l.count { let c = s[at + k]; let d = l[k]; if c != d && !(c >= 65 && c <= 90 && c + 32 == d) && !(d >= 65 && d <= 90 && d + 32 == c) { return false } }
            return true
        }

        while i < n {
            guard s[i] == 0x3C /* < */ else { i += 1; continue }
            // comment
            if starts(i, "<!--") {
                flushText(i)
                var j = i + 4
                while j + 3 <= n && !(s[j] == 0x2D && s[j + 1] == 0x2D && s[j + 2] == 0x3E) { j += 1 }
                let content = String(decoding: s[min(i + 4, n)..<min(j, n)], as: UTF8.self)
                tokens.append(.comment(content))
                i = min(j + 3, n); textStart = i; continue
            }
            if starts(i, "<!") || starts(i, "<?") {
                flushText(i)
                var j = i + 2
                while j < n && s[j] != 0x3E { j += 1 }
                tokens.append(.doctype(String(decoding: s[(i + 2)..<min(j, n)], as: UTF8.self)))
                i = min(j + 1, n); textStart = i; continue
            }
            // tag?
            var j = i + 1
            let isEnd = j < n && s[j] == 0x2F
            if isEnd { j += 1 }
            let nameStart = j
            while j < n, isNameChar(s[j]) { j += 1 }
            guard j > nameStart else { i += 1; continue }
            let name = String(decoding: s[nameStart..<j], as: UTF8.self).lowercased()
            // attributes
            var attrs: [HTMLToken.Attribute] = []
            var selfClosing = false
            var closed = false
            while j < n {
                while j < n, isSpace(s[j]) { j += 1 }
                guard j < n else { break }
                if s[j] == 0x3E { j += 1; closed = true; break }
                if s[j] == 0x2F { selfClosing = true; j += 1; continue }
                let aStart = j
                while j < n, !isSpace(s[j]), s[j] != 0x3D, s[j] != 0x3E, s[j] != 0x2F || (j == aStart) { j += 1 }
                let aName = String(decoding: s[aStart..<j], as: UTF8.self).lowercased()
                var aValue: String? = nil
                var k = j
                while k < n, isSpace(s[k]) { k += 1 }
                if k < n, s[k] == 0x3D {
                    k += 1
                    while k < n, isSpace(s[k]) { k += 1 }
                    if k < n, s[k] == 0x22 || s[k] == 0x27 {
                        let q = s[k]; k += 1
                        let vStart = k
                        while k < n, s[k] != q { k += 1 }
                        aValue = String(decoding: s[vStart..<min(k, n)], as: UTF8.self)
                        k = min(k + 1, n)
                    } else {
                        let vStart = k
                        while k < n, !isSpace(s[k]), s[k] != 0x3E { k += 1 }
                        aValue = String(decoding: s[vStart..<k], as: UTF8.self)
                    }
                    j = k
                }
                if !aName.isEmpty { attrs.append(.init(name: aName, value: aValue.map(HTMLText.decodeEntities))) }
                if j == aStart { j += 1 }
            }
            if !closed { i = n; flushText(i); break }
            flushText(i)
            if isEnd {
                tokens.append(.endTag(name: name))
            } else {
                tokens.append(.startTag(name: name, attributes: attrs, selfClosing: selfClosing || voidElements.contains(name)))
                if rawTextElements.contains(name) && !selfClosing {
                    // scan to </name>
                    var k = j
                    var found = n
                    while k < n {
                        if s[k] == 0x3C && starts(k, "</" + name) {
                            var m = k + 2 + name.count
                            while m < n, isSpace(s[m]) { m += 1 }
                            if m < n, s[m] == 0x3E { found = k; break }
                        }
                        k += 1
                    }
                    tokens.append(.rawText(element: name, content: String(decoding: s[j..<found], as: UTF8.self)))
                    if found < n {
                        tokens.append(.endTag(name: name))
                        var m = found + 2 + name.count
                        while m < n, s[m] != 0x3E { m += 1 }
                        j = min(m + 1, n)
                    } else { j = n }
                }
            }
            i = j; textStart = i
        }
        flushText(n)
        return tokens
    }

    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C }
    private static func isNameChar(_ c: UInt8) -> Bool { (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F || c == 0x3A }

    /// Serialises tokens back to HTML.
    public static func serialize(_ tokens: [HTMLToken]) -> String {
        var out = ""
        out.reserveCapacity(tokens.count * 16)
        for t in tokens {
            switch t {
            case .text(let s): out += s
            case .comment(let c): out += "<!--\(c)-->"
            case .doctype(let d): out += "<!\(d)>"
            case .rawText(_, let c): out += c
            case .endTag(let name): out += "</\(name)>"
            case .startTag(let name, let attrs, let selfClosing):
                out += "<" + name
                for a in attrs {
                    out += " " + a.name
                    if let v = a.value { out += "=\"" + escapeAttribute(v) + "\"" }
                }
                out += (selfClosing && !voidElements.contains(name)) ? "/>" : ">"
            }
        }
        return out
    }

    public static func escapeAttribute(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }
}
