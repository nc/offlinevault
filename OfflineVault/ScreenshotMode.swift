import SwiftUI
import WebKit
import OfflineVaultCore

/// DEBUG-only: `OFFLINEVAULT_SCREENSHOTS=/path/dir` makes the app walk its screens in dark mode, render each one
/// (a composited grab of the window, so WKWebView and SwiftUI layers are included) and quit. Used for the website.
#if DEBUG
@MainActor enum ScreenshotMode {
    static var directory: URL? { ProcessInfo.processInfo.environment["OFFLINEVAULT_SCREENSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) } }

    static func runIfRequested(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if let questions = env["OFFLINEVAULT_ASK_FILE"], let out = env["OFFLINEVAULT_ASK_OUT"] {
            Task { await answerFile(URL(fileURLWithPath: questions), to: URL(fileURLWithPath: out), model: model); NSApp.terminate(nil) }
            return
        }
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApp.appearance = NSAppearance(named: env["OFFLINEVAULT_SCREENSHOTS_APPEARANCE"] == "light" ? .aqua : .darkAqua)
        Task {
            if let questions = env["OFFLINEVAULT_ASK"]?.split(separator: "|").map({ $0.trimmingCharacters(in: .whitespaces) }), !questions.isEmpty {
                await ask(questions, model: model, dir: dir)
            } else if env["OFFLINEVAULT_INSTALL_FREE"] == "1" || env["OFFLINEVAULT_INSTALL_IDS"] != nil {
                await install(model: model, dir: dir)
            } else {
                await run(model: model, dir: dir)
            }
            NSApp.terminate(nil)
        }
    }

    struct EvalQuestion: Decodable { var id: String; var question: String }

    /// One answered question, in the shape `scripts/eval/run_eval.py run --provider file` reads.
    struct EvalAnswer: Codable {
        struct Quote: Codable { var label: Int; var text: String }
        /// `text` is the passage the model was given, so a grounding audit can hold each claim against its source.
        struct Source: Codable { var label: Int; var kind: String; var title: String; var location: String; var text: String }
        var id: String
        var question: String
        /// The text the person would see, after CitationVerifier; empty with `error` set when generation failed.
        var answer: String
        var quotes: [Quote]
        var unverified: [String]
        var sources: [Source]
        /// Label of the Field Guide passage shown word for word before the model's text; `answer` starts with it.
        var leading: Int?
        /// True when the app replied with `Prompting.refusal` instead of calling the model.
        var refused: Bool
        var seconds: Double
        var error: String?
    }

    /// `OFFLINEVAULT_ASK_FILE=questions.json OFFLINEVAULT_ASK_OUT=answers.json`: answers every `{id, question}` of the
    /// input in a fresh conversation with library search on, no screenshots, and rewrites the output after each answer,
    /// so a crash loses nothing and a relaunch resumes at the first id the output lacks. The model is the one the app
    /// would load; `-selectedModelFile <file>` on the command line picks another for the run.
    static func answerFile(_ input: URL, to output: URL, model: AppModel) async {
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        let decoder = JSONDecoder()
        guard let questions = try? decoder.decode([EvalQuestion].self, from: Data(contentsOf: input)) else { NSLog("ScreenshotMode: cannot read questions at \(input.path)"); return }
        var answers = (try? decoder.decode([EvalAnswer].self, from: Data(contentsOf: output))) ?? []
        // An answer that failed with a provider error (model still loading, server restart) is asked again on relaunch.
        let done = Set(answers.filter { $0.error == nil }.map(\.id))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        model.section = .chat
        model.chat.searchLibrary = true
        var waited = 0.0
        while model.chat.modelName == nil && waited < 900 { await wait(1); waited += 1 }
        guard let modelName = model.chat.modelName else { NSLog("ScreenshotMode: no model loaded after \(Int(waited))s"); return }
        NSLog("ScreenshotMode: \(questions.count) questions for \(modelName), \(done.count) already answered in \(output.lastPathComponent)")
        for q in questions where !done.contains(q.id) {
            model.chat.newConversation(); await wait(0.3)
            guard let conversation = model.chat.current else { continue }
            let started = Date()
            model.chat.input = q.question; model.chat.send()
            waited = 0
            while (model.chat.isGenerating || model.chat.messages.count < 2) && waited < 900 { await wait(0.5); waited += 0.5 }
            if model.chat.isGenerating { model.chat.stop(); await wait(2) }
            let seconds = Date().timeIntervalSince(started)
            if let m = model.chat.messages.last, m.role == .assistant {
                answers.removeAll { $0.id == q.id }
                answers.append(evalAnswer(for: q, message: m, seconds: seconds))
                if let data = try? encoder.encode(answers) { try? data.write(to: output, options: .atomic) }
                NSLog("ScreenshotMode: \(q.id) \(String(format: "%.1f", seconds))s \(m.sources.count) sources \(m.error ?? "")")
            }
            model.chat.delete(conversation)
        }
    }

    static func evalAnswer(for q: EvalQuestion, message m: ChatMessage, seconds: Double) -> EvalAnswer {
        let g = Grounding.ground(answer: m.content, passages: m.sources)
        var quotes: [EvalAnswer.Quote] = [], unverified: [String] = []
        // The scorer reads what the person sees: the verbatim procedure first, then the model's text.
        var shown = m.content
        if let lead = m.leadingPassage {
            shown = "\(TranscriptView.leadHeading): \(lead.source.title)\n\(lead.text)\n\n\(TranscriptView.assistantAddsHeading)\n" + m.content
            quotes.append(EvalAnswer.Quote(label: lead.label, text: lead.text))
        }
        for segment in g.segments {
            switch segment {
            case .claim(_, let found): quotes += found.map { EvalAnswer.Quote(label: $0.label, text: $0.text) }
            case .unverified(let text, _): unverified.append(text)
            case .prose: break
            }
        }
        // A refusal is either the fixed no-source reply or the sources-only answer that quotes passages without computing.
        let refused = Prompting.highStakes(q.question).map { c in [true, false].contains { m.content == Prompting.refusal(for: c, libraryOn: $0) } || m.content.contains("This is what your library says, word for word") } ?? false
        let sources = m.sources.map { EvalAnswer.Source(label: $0.label, kind: $0.source.kindLabel, title: $0.source.title, location: location($0.source), text: $0.text) }
        return EvalAnswer(id: q.id, question: q.question, answer: shown, quotes: quotes, unverified: unverified, sources: sources, leading: m.leadingPassageLabel,
                          refused: refused, seconds: (seconds * 10).rounded() / 10, error: m.error)
    }

    static func location(_ s: SourceRef) -> String {
        switch s {
        case .zimArticle(let book, let path, _): return "\(book)/\(path)"
        case .page(_, _, let url): return url
        case .video(let id, _, let start): return start.map { "\(id)@\(Int($0))s" } ?? id
        case .document(let id, _, let page): return "\(id)#page\(page)"
        }
    }

    /// `OFFLINEVAULT_ASK="q1|q2"`: asks each question in a fresh conversation, captures the window at the end of the
    /// answer (`ask-N.png`) and at its start (`ask-N-top.png`, where a Field Guide procedure leads), and the whole
    /// transcript (`ask-N-transcript.png`), then opens the first quote of the last answer and captures the
    /// highlighted passage (`ask-open.png`). `ask-report.txt` lists each answer's claims, quotes and counts, so a
    /// reviewer can re-run the same questions and compare.
    static func ask(_ questions: [String], model: AppModel, dir: URL) async {
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        await wait(3)
        if let w = window() { w.setContentSize(NSSize(width: 1440, height: 900)); w.center() }
        model.section = .chat
        model.chat.searchLibrary = true
        var waited = 0.0
        while model.chat.modelName == nil && waited < 240 { await wait(1); waited += 1 }
        var report = "model: \(model.chat.modelName ?? "none")\n"
        var created: [Conversation] = []
        var firstQuote: (SourceRef, Quote)?, firstWebQuote: (SourceRef, Quote)?
        for (i, q) in questions.enumerated() {
            model.chat.newConversation(); await wait(0.5)
            if let c = model.chat.current { created.append(c) }
            model.chat.input = q; model.chat.send()
            waited = 0
            while (model.chat.isGenerating || model.chat.messages.count < 2) && waited < 600 { await wait(1); waited += 1 }
            await wait(1.5)
            await capture("ask-\(i + 1)", dir: dir, model: model)
            captureTranscript("ask-\(i + 1)-transcript", dir: dir)
            conversationTextView()?.scroll(.zero); await wait(0.5)
            await capture("ask-\(i + 1)-top", dir: dir, model: model)
            guard let m = model.chat.messages.last, m.role == .assistant else { continue }
            let g = Grounding.ground(answer: m.content, passages: m.sources)
            report += "\n\(i + 1). \(q)\n   sources \(m.sources.count), supported \(g.supportedClaims), unverified \(g.unverifiedClaims)\n"
            if let lead = m.leadingPassage { report += "   lead [\(lead.label)] \(lead.source.title) (\(lead.text.count) chars)\n" }
            for segment in g.segments {
                switch segment {
                case .claim(let text, let quotes):
                    report += "   + \(text)\n" + quotes.map { "       [\($0.label)] \(String(format: "%.2f", $0.score)) \"\($0.text)\"\n" }.joined()
                    if let quote = quotes.first, let p = m.sources.first(where: { $0.label == quote.label }) {
                        if firstQuote == nil { firstQuote = (p.source, quote) }
                        switch p.source { case .zimArticle, .page: if firstWebQuote == nil { firstWebQuote = (p.source, quote) }; default: break }
                    }
                case .unverified(let text, let labels): report += "   ? \(text) \(labels)\n"
                case .prose: break
                }
            }
            report += "   --- answer ---\n\(m.content)\n   --- \(Prompting.sourcesBlock(m.sources))\n"
        }
        try? report.write(to: dir.appendingPathComponent("ask-report.txt"), atomically: true, encoding: .utf8)
        // An article or saved page shows the highlight; a PDF or video only opens at its page or time.
        if let (source, quote) = firstWebQuote ?? firstQuote {
            model.open(source, highlight: TranscriptView.quoteNeedle(quote))
            await wait(6)
            await capture("ask-open", dir: dir, model: model)
        }
        for c in created { model.chat.delete(c) }
    }

    /// The transcript text view drawn at its full document height, so an answer longer than the window is not clipped.
    static func conversationTextView() -> NSTextView? {
        func textView(in view: NSView) -> NSTextView? {
            if let t = view as? NSTextView, t.accessibilityLabel() == "Conversation" { return t }
            for sub in view.subviews { if let t = textView(in: sub) { return t } }
            return nil
        }
        return window()?.contentView.flatMap(textView(in:))
    }

    static func captureTranscript(_ name: String, dir: URL) {
        guard let w = window(), let text = conversationTextView() else { return }
        let bounds = text.bounds
        guard let rep = text.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        text.cacheDisplay(in: bounds, to: rep)
        let shot = NSImage(size: bounds.size); shot.addRepresentation(rep)
        let scale = w.backingScaleFactor
        let px = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        w.effectiveAppearance.performAsCurrentDrawingAppearance { NSColor.windowBackgroundColor.setFill() }
        NSRect(origin: .zero, size: px).fill()
        shot.draw(in: NSRect(origin: .zero, size: px))
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }

    /// `OFFLINEVAULT_INSTALL_FREE=1`: checks the catalogue, downloads what the current plan allows in the Free tier, waits
    /// for the installs and writes `install-report.txt` (the plan line, every change with its tier and verdict, what
    /// ended up installed) plus `install.png` of the Library. Rerunnable proof that a Mac with no key gets the free
    /// tier and nothing else: launch with a fresh `-libraryPath` and `-useFixtureServer YES`.
    /// `OFFLINEVAULT_INSTALL_IDS=a,b` downloads those artefacts instead, as far as the plan allows, and waits up to six
    /// hours; `OFFLINEVAULT_IMPORT_LICENCE=<file>` imports a licence file first (the eval uses the committed dev ones).
    static func install(model: AppModel, dir: URL) async {
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        let env = ProcessInfo.processInfo.environment
        var waited = 0.0
        while model.layout == nil && waited < 30 { await wait(1); waited += 1 }
        var report = "library: \(model.layout?.root.path ?? "none opened (the folder needs the .offlinevault-library marker)")\n"
        if let licence = env["OFFLINEVAULT_IMPORT_LICENCE"] { model.importLicence(from: URL(fileURLWithPath: licence)); await wait(1); report += "imported licence: \(licence)\n" }
        report += "plan: \(model.entitlements.label), source \(model.entitlements.source), licence \(model.licenceStatus.summary)\n"
        await model.checkForUpdates(interactive: false)
        model.showUpdateSheet = false
        if let b = model.banner { report += "banner: \(b.title): \(b.message)\n" }
        if let check = model.updateCheck {
            report += "catalogue: \(check.trust.title), release \(check.manifest.version)\n"
            for c in check.diff.changes {
                report += "  \(c.id) [\(c.artefact.contentTier.rawValue)]: \(model.entitlements.denial(for: c.artefact)?.title ?? "allowed")\n"
            }
            let ids = env["OFFLINEVAULT_INSTALL_IDS"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let chosen = ids.map { wanted in check.diff.changes.filter { wanted.contains($0.id) } } ?? check.diff.changes.filter { $0.artefact.contentTier == .free }
            for id in ids ?? [] where !chosen.contains(where: { $0.id == id }) { report += "  \(id): not in the diff (installed already, or not in this catalogue)\n" }
            model.applyUpdates(chosen)
            let limit = ids == nil ? 600.0 : 6 * 3600.0
            waited = 0
            repeat { await wait(1); waited += 1 } while (model.downloads.activeCount > 0 || waited < 3) && waited < limit
            report += "downloads finished after \(Int(waited))s\n"
            for item in model.downloads.items { if case .failed(let e) = item.state { report += "  failed: \(item.title): \(e.title) \(e.message)\n" } }
        } else {
            report += "no catalogue: the check failed\n"
        }
        report += "installed: \(model.installed.map(\.id).sorted().joined(separator: ", "))\n"
        model.section = .library
        await wait(2)
        await capture("install", dir: dir, model: model)
        try? report.write(to: dir.appendingPathComponent("install-report.txt"), atomically: true, encoding: .utf8)
    }

    static func window() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.title == "OfflineVault" } ?? NSApp.windows.first { $0.isVisible } }

    /// `OFFLINEVAULT_SCREENSHOTS_ONLY=library,maps` restricts the walk while iterating on one screen.
    static func wanted(_ name: String) -> Bool {
        guard let only = ProcessInfo.processInfo.environment["OFFLINEVAULT_SCREENSHOTS_ONLY"], !only.isEmpty else { return true }
        return only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains(name)
    }

    static func run(model: AppModel, dir: URL) async {
        func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        await wait(3)
        if let w = window() { w.setContentSize(NSSize(width: 1440, height: 900)); w.center() }
        await wait(1)
        // Chat: a fresh conversation with a grounded answer.
        // Earlier screenshot runs leave identical conversations behind; keep the sidebar clean.
        for c in model.chat.conversations where c.title.hasPrefix("My friend is bleeding heavily") { model.chat.delete(c) }
        if wanted("chat") {
        model.section = .chat
        model.chat.newConversation()
        model.chat.searchLibrary = true
        await wait(1)
        model.chat.input = "My friend is bleeding heavily from the thigh and pressure isn't stopping it. What do I do?"
        model.chat.send()
        var waited = 0.0
        while (model.chat.isGenerating || model.chat.messages.count < 2) && waited < 180 { await wait(1); waited += 1 }
        await wait(1.5)
        await capture("chat", dir: dir, model: model)
        }
        // Scenarios
        if wanted("scenarios") {
        model.section = .scenarios
        await wait(1.5)
        if let s = model.scenariosScreen.selected ?? Scenario.load().first { model.scenariosScreen.selected = Scenario.load().first { $0.id == "bleeding" } ?? s }
        await wait(1.5)
        await capture("scenarios", dir: dir, model: model)
        }
        // Reference: open an article
        if wanted("library") {
        model.section = .library
        await wait(1.5)
        if let book = model.books.first {
            model.libraryScreen.selectedBook = book          // selecting a book loads its main page…
            await wait(1)
            model.libraryScreen.query = "water"; await wait(2.5)
            if let hit = model.libraryScreen.hits.first {   // …then the search hit replaces it
                model.libraryScreen.articleURL = model.kiwix.articleURL(bookName: hit.bookName, path: hit.path); model.libraryScreen.articleTitle = hit.title
            }
        }
        await wait(8)
        await capture("library", dir: dir, model: model)
        }
        // Documents: a page of the first PDF with a search
        if wanted("documents") {
        model.section = .documents
        await wait(1.5)
        model.documentsScreen.query = "tourniquet"
        await wait(2)
        if let hit = model.documentsScreen.hits.first { model.documentsScreen.targetUnit = hit.page; model.documentsScreen.selected = hit.document }
        await wait(3)
        await capture("documents", dir: dir, model: model)
        }
        // Maps
        if wanted("maps") {
        model.section = .maps
        await wait(6)
        await capture("maps", dir: dir, model: model)
        }
        // Videos
        if wanted("videos") {
        model.section = .videos
        await wait(1.5)
        if let v = try? model.videoLibrary?.videos(status: .downloaded).first { model.videosScreen.selected = v }
        await wait(3)
        await capture("videos", dir: dir, model: model)
        model.videosScreen.player.pause()
        }
        // Readiness: run the drill
        if wanted("readiness") {
        model.section = .readiness
        await wait(1)
        model.runReadiness()
        var waited = 0.0
        while model.readinessRunning && waited < 240 { await wait(1); waited += 1 }
        await wait(1.5)
        await capture("readiness", dir: dir, model: model)
        }
        // Share (QR) and Backup
        if wanted("share") {
        model.section = .share
        model.setSharing(true)
        await wait(3)
        await capture("share", dir: dir, model: model)
        model.setSharing(false)
        model.section = .backup
        await wait(1.5)
        await capture("backup", dir: dir, model: model)
        }
        // Library updates sheet with the catalogue trust badge
        if wanted("updates") {
        model.section = .downloads
        await wait(1)
        await model.checkForUpdates(interactive: true)
        // The check decides what the capture shows; a failed check leaves a banner the capture clears.
        NSLog("ScreenshotMode: updates from %@: %@", Config.updatesBaseURL.absoluteString, model.updateCheck.map { "\($0.trust)" } ?? model.banner.map { "failed: \($0.title)" } ?? "no check")
        await wait(2.5)
        await capture("updates", dir: dir, model: model)
        model.showUpdateSheet = false
        await wait(0.5)
        }
        // Settings › Licence
        if wanted("licence") {
        model.section = .settings
        model.settingsTab = .licence
        await wait(2.5)
        await capture("licence", dir: dir, model: model)
        model.settingsTab = .general
        }
        // Global search
        if wanted("search") {
        model.section = .chat
        await wait(1)
        model.globalSearch.query = "tourniquet"
        model.globalSearch.isPresented = true
        model.globalSearch.run { q in await model.chat.retrieve(q) }
        await wait(3)
        await capture("search", dir: dir, model: model)
        model.globalSearch.isPresented = false
        await wait(0.5)
        }
        // Leave no trace of the run in the user's chat history.
        for c in model.chat.conversations where c.title.hasPrefix("My friend is bleeding heavily") { model.chat.delete(c) }
    }

    /// Captures the window exactly as composited on screen (SwiftUI layers, toolbar and WKWebView included).
    /// An app may capture its own windows without the Screen Recording permission.
    static func capture(_ name: String, dir: URL, model: AppModel) async {
        // Nothing modal may sit over the window (no banners, no import sheet) except the sheet a screen is about.
        let keepsSheet = name == "updates" || name == "search"
        if name != "updates" { model.showUpdateSheet = false }
        model.showImportSheet = false; model.banners.removeAll()
        if !keepsSheet { for w in NSApp.windows { if let sheet = w.attachedSheet { w.endSheet(sheet) } } }
        try? await Task.sleep(nanoseconds: 600_000_000)
        guard let w = window() else { NSLog("ScreenshotMode: no visible window for \(name) (\(NSApp.windows.count) windows)"); return }
        w.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 400_000_000)
        func grab(_ win: NSWindow) -> CGImage? { CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(win.windowNumber), [.boundsIgnoreFraming, .bestResolution]) }
        guard let cg = grab(w) else { NSLog("ScreenshotMode: CGWindowListCreateImage failed for \(name)"); return }
        var image = NSImage(cgImage: cg, size: w.frame.size)
        if let sheet = w.attachedSheet, let sg = grab(sheet) {
            // A sheet is its own window: composite it at its position inside the main window.
            let base = image; let sheetImage = NSImage(cgImage: sg, size: sheet.frame.size)
            let origin = NSPoint(x: sheet.frame.minX - w.frame.minX, y: sheet.frame.minY - w.frame.minY)
            image = NSImage(size: w.frame.size, flipped: false) { rect in
                base.draw(in: rect); sheetImage.draw(in: NSRect(origin: origin, size: sheet.frame.size)); return true
            }
        }
        let scale = w.backingScaleFactor
        let px = NSSize(width: w.frame.width * scale, height: w.frame.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: px), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        NSLog("ScreenshotMode: wrote \(name).png \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
}
#endif
