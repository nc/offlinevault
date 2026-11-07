import Foundation

public struct SubtitleCue: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

/// Parses WebVTT and SRT. YouTube auto-captions repeat text across overlapping cues with <c> tags; those are cleaned and de-duplicated.
public enum SubtitleParser {
    public static func parse(_ content: String) -> [SubtitleCue] {
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var cues: [SubtitleCue] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let (s, e) = parseTiming(line) {
                var text: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    text.append(lines[i]); i += 1
                }
                let cleaned = clean(text.joined(separator: " "))
                if !cleaned.isEmpty {
                    if let last = cues.last, last.text == cleaned || cleaned.hasPrefix(last.text) && s - last.start < 8 {
                        cues[cues.count - 1].end = e
                        cues[cues.count - 1].text = cleaned
                    } else if let last = cues.last, last.text.hasSuffix(cleaned) {
                        cues[cues.count - 1].end = e
                    } else {
                        cues.append(SubtitleCue(start: s, end: e, text: cleaned))
                    }
                }
            } else { i += 1 }
        }
        return cues
    }

    static func parseTiming(_ line: String) -> (Double, Double)? {
        guard line.contains("-->") else { return nil }
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2, let s = parseTimestamp(parts[0]), let e = parseTimestamp(parts[1].split(separator: " ").first.map(String.init) ?? parts[1]) else { return nil }
        return (s, e)
    }

    public static func parseTimestamp(_ raw: String) -> Double? {
        let t = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let comps = t.split(separator: ":").map(String.init)
        guard (2...3).contains(comps.count) else { return nil }
        var total = 0.0
        for c in comps { guard let v = Double(c) else { return nil }; total = total * 60 + v }
        return total
    }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        t = HTMLText.decodeEntities(t)
        t = t.replacingOccurrences(of: "\\[(Music|Applause|Laughter|♪)[^\\]]*\\]", with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Groups cues into windows of roughly `windowSeconds` for indexing; each window keeps its start time.
    public static func windows(_ cues: [SubtitleCue], windowSeconds: Double = 20, maxChars: Int = 500) -> [SubtitleCue] {
        var out: [SubtitleCue] = []
        var current: SubtitleCue?
        for c in cues {
            if var cur = current, c.start - cur.start < windowSeconds, cur.text.count + c.text.count < maxChars {
                cur.text += " " + c.text; cur.end = c.end; current = cur
            } else {
                if let cur = current { out.append(cur) }
                current = c
            }
        }
        if let cur = current { out.append(cur) }
        return out
    }
}
