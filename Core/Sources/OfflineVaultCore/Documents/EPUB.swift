import Foundation

/// Minimal EPUB 2/3 reader: unzips with the system tar, follows container.xml → OPF → spine, extracts chapter text.
/// Enough for indexing and a plain reading view; not a full rendering engine.
public struct EPUB: Sendable {
    public struct Chapter: Sendable, Equatable { public var title: String; public var href: String; public var text: String; public var html: String }
    public var title: String?
    public var author: String?
    public var chapters: [Chapter]
    /// Folder the EPUB was extracted into (kept next to the file as `<name>.epub.d`), for the viewer.
    public var extractedRoot: URL

    public static func title(of url: URL) -> String? { (try? open(url, extractTextOnly: true))?.title }

    public static func open(_ url: URL, extractTextOnly: Bool = false) throws -> EPUB {
        let fm = FileManager.default
        let dir = url.appendingPathExtension("d")
        if !fm.fileExists(atPath: dir.appendingPathComponent("META-INF/container.xml").path) {
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Archive.extract(url, to: dir)
        }
        let containerXML = try String(contentsOf: dir.appendingPathComponent("META-INF/container.xml"), encoding: .utf8)
        guard let opfRel = firstAttribute("full-path", in: containerXML, tag: "rootfile") else { throw UserFacingError("Not a readable EPUB", message: "\(url.lastPathComponent) has no OPF package file.") }
        let opfURL = dir.appendingPathComponent(opfRel)
        let opf = try String(contentsOf: opfURL, encoding: .utf8)
        let opfDir = opfURL.deletingLastPathComponent()
        let title = textOf(tag: "dc:title", in: opf)
        let author = textOf(tag: "dc:creator", in: opf)
        // manifest id → href
        var manifest: [String: String] = [:]
        for item in matches("<item\\b[^>]*>", in: opf) {
            if let id = attribute("id", in: item), let href = attribute("href", in: item) { manifest[id] = href }
        }
        var chapters: [Chapter] = []
        for ref in matches("<itemref\\b[^>]*>", in: opf) {
            guard let idref = attribute("idref", in: ref), let href = manifest[idref] else { continue }
            let file = opfDir.appendingPathComponent(href.removingPercentEncoding ?? href)
            guard let html = (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .isoLatin1)) else { continue }
            let ex = HTMLText.extract(from: html)
            let text = ex.body
            if text.count < 40 { continue } // cover / blank pages
            chapters.append(Chapter(title: ex.title.isEmpty ? "Chapter \(chapters.count + 1)" : ex.title, href: href, text: text, html: extractTextOnly ? "" : html))
        }
        return EPUB(title: title, author: author, chapters: chapters, extractedRoot: dir)
    }

    static func matches(_ pattern: String, in s: String) -> [String] {
        let re = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }
    static func attribute(_ name: String, in tag: String) -> String? {
        let re = try! NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*[\"']([^\"']*)[\"']", options: [.caseInsensitive])
        guard let m = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)), let r = Range(m.range(at: 1), in: tag) else { return nil }
        return HTMLText.decodeEntities(String(tag[r]))
    }
    static func firstAttribute(_ name: String, in s: String, tag: String) -> String? { matches("<\(tag)\\b[^>]*>", in: s).first.flatMap { attribute(name, in: $0) } }
    static func textOf(tag: String, in s: String) -> String? {
        let re = try! NSRegularExpression(pattern: "<\(tag)\\b[^>]*>(.*?)</\(tag)>", options: [.caseInsensitive, .dotMatchesLineSeparators])
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { return nil }
        let t = HTMLText.decodeEntities(String(s[r])).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
