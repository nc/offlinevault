import SwiftUI
import AppKit
import OfflineVaultCore

/// The whole conversation in one read-only NSTextView (selection and copy work across messages). A finished answer
/// with sources is rendered through `Grounding`: each cited sentence is followed by the verbatim quote that supports
/// it, and a cited sentence with no supporting quote is tagged "Unverified". Only the streaming message is
/// re-rendered while tokens arrive.
struct TranscriptView: NSViewRepresentable {
    let messages: [ChatMessage]
    let onOpen: (SourceRef, _ highlight: String?) -> Void
    static let citeScheme = "ovcite"

    final class Coordinator: NSObject, NSTextViewDelegate {
        var messages: [ChatMessage] = []
        var onOpen: (SourceRef, String?) -> Void = { _, _ in }
        var renderedIds: [String] = []
        var streamingRange: NSRange?
        var streamingId: String?
        var lastContentLength = 0
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)), url.scheme == TranscriptView.citeScheme else { return false }
            let label = Int(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) ?? -1
            let highlight = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
            if let m = messages.first(where: { $0.id == url.host }), let p = m.sources.first(where: { $0.label == label }) { onOpen(p.source, highlight) }
            return true
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        // TextKit 1 from the start: the quote boxes are drawn by a layout manager subclass.
        let text = NSTextView(usingTextLayoutManager: false)
        text.textContainer?.replaceLayoutManager(QuoteBoxLayoutManager())
        text.isEditable = false; text.isSelectable = true; text.isRichText = true; text.drawsBackground = false
        text.textContainerInset = NSSize(width: 18, height: 14); text.isAutomaticLinkDetectionEnabled = false
        text.linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
        text.delegate = context.coordinator; text.isVerticallyResizable = true; text.isHorizontallyResizable = false; text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true; text.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityLabel("Conversation")
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView, let storage = text.textStorage else { return }
        let co = context.coordinator
        co.messages = messages; co.onOpen = onOpen
        let wasAtBottom = scroll.contentView.bounds.maxY >= (text.frame.height - 60)
        let ids = messages.map(\.id)
        // Fast path: same messages, only the last one is streaming → replace just its range.
        if ids == co.renderedIds, let last = messages.last, last.isStreaming, let range = co.streamingRange, co.streamingId == last.id, range.location + range.length == storage.length {
            let rendered = Self.render([last], first: messages.count == 1)
            storage.beginEditing()
            storage.replaceCharacters(in: range, with: rendered)
            storage.endEditing()
            co.streamingRange = NSRange(location: range.location, length: rendered.length)
        } else {
            let full = NSMutableAttributedString()
            var lastRange: NSRange?
            for (i, m) in messages.enumerated() {
                let r = Self.render([m], first: i == 0)
                if i == messages.count - 1 { lastRange = NSRange(location: full.length, length: r.length) }
                full.append(r)
            }
            let selected = text.selectedRanges
            storage.beginEditing()
            storage.setAttributedString(full)
            storage.endEditing()
            if let r = selected.first?.rangeValue, r.length > 0, r.upperBound <= storage.length { text.selectedRanges = selected }
            co.renderedIds = ids; co.streamingRange = lastRange; co.streamingId = messages.last?.id
        }
        if wasAtBottom { text.scrollToEndOfDocument(nil) }
    }

    // MARK: Rendering

    @MainActor static func render(_ messages: [ChatMessage], first: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let body = NSFont.systemFont(ofSize: NSFont.systemFontSize + 1)
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let header = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        let para = NSMutableParagraphStyle(); para.paragraphSpacing = 5; para.lineSpacing = 2
        let gap = NSMutableParagraphStyle(); gap.paragraphSpacingBefore = 18
        for m in messages {
            out.append(NSAttributedString(string: (m.role == .user ? "YOU" : "OFFLINEVAULT") + "\n", attributes: [.font: header, .foregroundColor: m.role == .user ? NSColor.secondaryLabelColor : NSColor.controlAccentColor, .paragraphStyle: first ? para : gap, .kern: 0.6]))
            if let e = m.error { out.append(NSAttributedString(string: "⚠︎ " + e + "\n", attributes: [.font: small, .foregroundColor: NSColor.systemOrange, .paragraphStyle: para])) }
            let grounded = grounding(for: m)
            if let lead = m.leadingPassage {
                out.append(NSAttributedString(string: "\(Self.leadHeading): \(lead.source.title)\n", attributes: [.font: header, .foregroundColor: NSColor.controlAccentColor, .paragraphStyle: para]))
                out.append(quoteBlock(Quote(label: lead.label, text: lead.text, range: 0..<(lead.text as NSString).length, score: 1), passage: lead, message: m, keepLines: true))
                out.append(NSAttributedString(string: Self.assistantAddsHeading + "\n", attributes: [.font: header, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
            }
            let content: NSMutableAttributedString
            if m.role == .user {
                content = NSMutableAttributedString(string: m.content, attributes: [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
            } else if let grounded {
                content = groundedBody(grounded, message: m, font: body, paragraph: para)
            } else {
                content = NSMutableAttributedString(attributedString: markdown(m.content, font: body, paragraph: para))
                linkCitations(in: content, message: m)
            }
            if m.role == .assistant, Prompting.isSafetyCritical(m.content) { tintSafety(content) }
            out.append(content)
            if m.isStreaming { out.append(NSAttributedString(string: " ▍", attributes: [.font: body, .foregroundColor: NSColor.tertiaryLabelColor])) }
            out.append(NSAttributedString(string: "\n", attributes: [.font: body, .paragraphStyle: para]))
            if m.role == .assistant, !m.isStreaming {
                let quoted = Set(grounded?.segments.flatMap { seg -> [Int] in if case .claim(_, let quotes) = seg { return quotes.map(\.label) }; return [] } ?? [])
                let others = m.sources.filter { !quoted.contains($0.label) && $0.label != m.leadingPassageLabel }
                if !others.isEmpty {
                    out.append(NSAttributedString(string: "Also considered: ", attributes: [.font: small, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: para]))
                    for (k, p) in others.enumerated() { out.append(NSAttributedString(string: "[\(p.label)] \(p.source.title)", attributes: [.font: small, .link: citeURL(m, p.label), .foregroundColor: NSColor.secondaryLabelColor, .toolTip: p.text])); if k < others.count - 1 { out.append(NSAttributedString(string: "  ·  ", attributes: [.font: small, .foregroundColor: NSColor.tertiaryLabelColor])) } }
                    out.append(NSAttributedString(string: "\n", attributes: [.font: small, .paragraphStyle: para]))
                }
                if m.sources.isEmpty, m.error == nil, !m.content.hasPrefix("I can't answer this from memory") {
                    let note = !m.usedLibrary ? "Answered from the model only — unverified." : (RetrievalCoordinator.shouldRetrieve(m.content) ? "No library sources matched this question." : nil)
                    if let note { out.append(NSAttributedString(string: note + "\n", attributes: [.font: small, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: para])) }
                }
            }
        }
        return out
    }

    /// Grounding is pure but not free; cache it per message so re-renders of a long conversation stay cheap.
    @MainActor static var groundingCache: [String: (content: String, answer: GroundedAnswer)] = [:]
    @MainActor static func grounding(for m: ChatMessage) -> GroundedAnswer? {
        guard m.role == .assistant, !m.isStreaming, !m.sources.isEmpty else { return nil }
        if let hit = groundingCache[m.id], hit.content == m.content { return hit.answer }
        let answer = Grounding.ground(answer: m.content, passages: m.sources)
        groundingCache[m.id] = (m.content, answer)
        return answer
    }

    static func groundedBody(_ g: GroundedAnswer, message m: ChatMessage, font: NSFont, paragraph para: NSParagraphStyle) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        var afterQuote = false
        for segment in g.segments {
            switch segment {
            case .prose(let text):
                // A quote box already ends the line, so the whitespace that separated the next sentence is spent.
                let shown = afterQuote ? String(text.drop { $0.isWhitespace }) : text
                guard !shown.isEmpty else { continue }
                out.append(markdown(shown, font: font, paragraph: para))
                afterQuote = false
            case .claim(let text, let quotes):
                out.append(markdown(text, font: font, paragraph: para))
                out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: para]))
                for q in quotes { if let p = m.sources.first(where: { $0.label == q.label }) { out.append(quoteBlock(q, passage: p, message: m)) } }
                afterQuote = true
            case .unverified(let text, _):
                out.append(unverifiedTag)
                let shown = text.hasPrefix("Unverified:") ? String(text.dropFirst("Unverified:".count)).trimmingCharacters(in: .whitespaces) : text
                out.append(markdown(shown, font: font, paragraph: para, color: .secondaryLabelColor))
                afterQuote = false
            }
        }
        return out
    }

    static let leadHeading = "From the Field Guide, human-checked"
    static let assistantAddsHeading = "The assistant adds:"

    static func citeURL(_ m: ChatMessage, _ label: Int) -> URL { URL(string: "\(citeScheme)://\(m.id)/\(label)")! }

    /// The link behind a quote carries the first words of the quote, so the viewer can scroll to and select them.
    static func quoteURL(_ m: ChatMessage, _ q: Quote) -> URL {
        var c = URLComponents(url: citeURL(m, q.label), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "q", value: quoteNeedle(q))]
        return c.url!
    }

    /// The first 80 characters of the quote, cut at a word, which is what the viewer searches for.
    static func quoteNeedle(_ q: Quote) -> String {
        guard q.text.count > 80 else { return q.text }
        let head = String(q.text.prefix(80))
        return head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
    }

    static let quoteFont: NSFont = {
        let size = NSFont.systemFontSize
        let descriptor = NSFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)?.withSymbolicTraits(.italic)
        return descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? NSFont.systemFont(ofSize: size)
    }()

    static let unverifiedTag: NSAttributedString = {
        let tag = NSMutableAttributedString(string: " Unverified ", attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), .foregroundColor: NSColor.systemOrange, .backgroundColor: NSColor.systemOrange.withAlphaComponent(0.16), .baselineOffset: 1])
        tag.append(NSAttributedString(string: " "))
        return tag
    }()

    /// A quote box: source icon, title and location (all opening the source), then the verbatim text in a serif italic
    /// so the source is visibly speaking rather than the model. `keepLines` keeps one paragraph per line, for a
    /// procedure whose lines are steps.
    static func quoteBlock(_ q: Quote, passage p: RetrievedPassage, message m: ChatMessage, keepLines: Bool = false) -> NSAttributedString {
        let url = quoteURL(m, q)
        let head = NSMutableParagraphStyle(); head.paragraphSpacing = 2; head.paragraphSpacingBefore = QuoteBoxLayoutManager.padding
        head.headIndent = QuoteBoxLayoutManager.inset; head.firstLineHeadIndent = QuoteBoxLayoutManager.inset; head.tailIndent = -QuoteBoxLayoutManager.inset
        let body = NSMutableParagraphStyle(); body.lineSpacing = 2; body.paragraphSpacing = QuoteBoxLayoutManager.padding + 8
        body.headIndent = QuoteBoxLayoutManager.inset; body.firstLineHeadIndent = QuoteBoxLayoutManager.inset; body.tailIndent = -QuoteBoxLayoutManager.inset
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let out = NSMutableAttributedString()
        if let img = NSImage(systemSymbolName: p.source.systemImage, accessibilityDescription: p.source.kindLabel)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) {
            let att = NSTextAttachment(); att.image = img.tinted(NSColor.controlAccentColor); att.bounds = CGRect(x: 0, y: -2, width: 13, height: 13)
            out.append(NSAttributedString(attachment: att)); out.append(NSAttributedString(string: " ", attributes: [.font: small, .paragraphStyle: head]))
        }
        var location = p.source.kindLabel
        switch p.source {
        case .document(_, _, let page): location += " · page \(page)"
        case .video(_, _, let s?): location += " · \(DurationFormat.string(s))"
        case .zimArticle(let book, _, _): location += " · \(book)"
        default: break
        }
        out.append(NSAttributedString(string: p.source.title, attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), .link: url, .paragraphStyle: head, .toolTip: "Open and highlight this passage"]))
        out.append(NSAttributedString(string: "  " + location, attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: head]))
        out.append(NSAttributedString(string: "   Open ↗\n", attributes: [.font: small, .link: url, .paragraphStyle: head, .toolTip: "Open and highlight this passage"]))
        // Extracted text soft-wraps mid-sentence; the quote stays verbatim in the model, the box shows it on one flow.
        let lines = keepLines ? q.text.components(separatedBy: .newlines) : [q.text.components(separatedBy: .newlines).joined(separator: " ")]
        let step = NSMutableParagraphStyle(); step.setParagraphStyle(body); step.paragraphSpacing = 4
        for (k, line) in lines.enumerated() {
            let last = k == lines.count - 1
            out.append(NSAttributedString(string: (k == 0 ? "“" : "") + line + (last ? "”" : "") + "\n", attributes: [.font: quoteFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: last ? body : step]))
        }
        // One value per quote, so two boxes under a [1][2] claim stay separate runs.
        out.addAttribute(.quoteBox, value: url.absoluteString, range: NSRange(location: 0, length: out.length))
        return out
    }

    static func linkCitations(in text: NSMutableAttributedString, message: ChatMessage) {
        let re = try! NSRegularExpression(pattern: "\\[(\\d{1,2}(?:\\s*,\\s*\\d{1,2})*)\\]")
        let s = text.string
        for match in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let inner = Range(match.range(at: 1), in: s) else { continue }
            let labels = s[inner].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let first = labels.first, message.sources.contains(where: { $0.label == first }) else { continue }
            text.addAttributes([.link: citeURL(message, first), .font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)], range: match.range)
        }
    }

    /// Safety-critical answers get a tinted note above them.
    static func tintSafety(_ text: NSMutableAttributedString) {
        let ps = NSMutableParagraphStyle(); ps.paragraphSpacing = 6
        text.insert(NSAttributedString(string: "⚠︎ Safety-critical topic — follow the cited source text, not just this summary.\n", attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold), .foregroundColor: NSColor.systemOrange, .paragraphStyle: ps]), at: 0)
    }

    static func markdown(_ s: String, font: NSFont, paragraph: NSParagraphStyle, color: NSColor = .labelColor) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        guard let attributed = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return NSAttributedString(string: s, attributes: base) }
        let out = NSMutableAttributedString()
        for run in attributed.runs {
            var attrs = base; var f = font
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
            if intent.contains(.code) { f = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) }
            attrs[.font] = f
            out.append(NSAttributedString(string: String(attributed[run.range].characters), attributes: attrs))
        }
        return out
    }
}

extension NSAttributedString.Key { static let quoteBox = NSAttributedString.Key("offlinevault.quoteBox") }

/// Draws a tinted, bordered box behind every run carrying `.quoteBox`: the union of the run's line fragments, with
/// the paragraphs' own indents leaving room for the padding.
final class QuoteBoxLayoutManager: NSLayoutManager {
    static let inset: CGFloat = 12
    static let padding: CGFloat = 6

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.quoteBox, in: visible) { value, range, _ in
            guard value != nil else { return }
            var run = NSRange()
            _ = storage.attribute(.quoteBox, at: range.location, longestEffectiveRange: &run, in: NSRange(location: 0, length: storage.length))
            var lines = NSRect.null
            enumerateLineFragments(forGlyphRange: glyphRange(forCharacterRange: run, actualCharacterRange: nil)) { rect, _, _, _, _ in lines = lines.union(rect) }
            guard !lines.isNull else { return }
            let box = NSRect(x: origin.x + 2, y: origin.y + lines.minY + 1, width: container.size.width - 4, height: lines.height - 10)
            let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(0.07).setFill(); path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.35).setStroke(); path.lineWidth = 1; path.stroke()
        }
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            color.set(); rect.fill()
            self.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1); return true
        }
        return img
    }
}
