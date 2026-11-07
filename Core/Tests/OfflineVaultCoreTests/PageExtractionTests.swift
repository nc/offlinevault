import XCTest
@testable import OfflineVaultCore

final class PageExtractionTests: XCTestCase {
    func testTokenizerRoundTripsAndHandlesRawText() {
        let html = "<!DOCTYPE html><p class=\"a\" data-x='1'>Hi &amp; bye<br/><script>if (a < b) { x = \"</p>\"; }</script></p><!-- c -->"
        let tokens = HTMLTokenizer.tokenize(html)
        XCTAssertTrue(tokens.contains(.rawText(element: "script", content: "if (a < b) { x = \"</p>\"; }")))
        XCTAssertTrue(tokens.contains(.startTag(name: "br", attributes: [], selfClosing: true)))
        XCTAssertTrue(tokens.contains(.startTag(name: "p", attributes: [.init(name: "class", value: "a"), .init(name: "data-x", value: "1")], selfClosing: false)))
        XCTAssertTrue(tokens.contains(.comment(" c ")))
        let out = HTMLTokenizer.serialize(tokens)
        XCTAssertTrue(out.contains("<script>if (a < b)"))
        XCTAssertTrue(out.contains("Hi &amp; bye"))
    }

    func testExtractsTitleAndArticleTextSkippingBoilerplate() {
        let ex = HTMLText.extract(from: Fixtures.string("sample_page.html"))
        XCTAssertEqual(ex.title, "Water purification in the field – Field Notes")
        XCTAssertTrue(ex.body.contains("rolling boil"))
        XCTAssertTrue(ex.body.contains("2,000 metres"), "entities decoded, nbsp normalised")
        XCTAssertTrue(ex.body.contains("0.2 microns"))
        XCTAssertFalse(ex.body.contains("Sponsored"), "aside skipped")
        XCTAssertFalse(ex.body.contains("dataLayer"), "scripts skipped")
        XCTAssertFalse(ex.body.contains("Home"), "nav skipped")
        XCTAssertFalse(ex.body.contains("Field Notes\n"), "footer skipped")
    }

    func testOrderedListItemsKeepTheirNumbersAndEachListRestarts() {
        let html = "<h2>What to do</h2><ol><li>Call for help.</li><li>Set up.<ul><li>gloves</li></ul></li></ol><h3>Later</h3><ol><li>Rest.</li></ol><ul><li>a bullet</li></ul>"
        XCTAssertEqual(HTMLText.extract(from: html).body, "What to do\n\n1. Call for help.\n\n2. Set up.\n\ngloves\n\nLater\n\n1. Rest.\n\na bullet")
    }

    func testEntityDecoding() {
        XCTAssertEqual(HTMLText.decodeEntities("a &lt; b &amp;&amp; c &gt; d &#169; &#x41; &hellip; &unknown;"), "a < b && c > d © A … &unknown;")
    }

    func testChunkingAndBestWindow() {
        let text = (1...40).map { "Paragraph \($0) talks about topic \($0 % 5) in some detail with enough words to count." }.joined(separator: "\n")
        let chunks = HTMLText.chunk(text, targetChars: 300, maxChars: 500)
        XCTAssertGreaterThan(chunks.count, 5)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 500 })
        let window = HTMLText.bestWindow(in: text, queryTerms: ["paragraph", "37"], maxChars: 200)
        XCTAssertTrue(window.contains("Paragraph 37"))
        XCTAssertLessThanOrEqual(window.count, 201)
    }

    func testArchiverInlinesAssetsStripsScriptsAndAddsCSP() async throws {
        let base = URL(string: "https://fieldnotes.example/guides/water.html")!
        let fetched = FetchLog()
        let archiver = PageArchiver(fetcher: { req in
            await fetched.add(req.url!.absoluteString)
            let url = req.url!
            func ok(_ body: String, _ type: String) -> (Data, URLResponse) { (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])!) }
            switch url.path {
            case "/static/site.css": return ok("body{color:red} .hero{background:url(/images/hero.png)}", "text/css")
            case "/images/hero.png", "/images/boil.jpg", "/static/bg.png": return ok("IMG", url.pathExtension == "png" ? "image/png" : "image/jpeg")
            default: return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
            }
        })
        let capture = try await archiver.archive(html: Fixtures.string("sample_page.html"), baseURL: base)
        let html = capture.html
        XCTAssertFalse(html.contains("<script"), "scripts removed")
        XCTAssertFalse(html.contains("tracker.example.com"), "trackers removed (script src, noscript pixel)")
        XCTAssertFalse(html.contains("<iframe"), "iframes removed")
        XCTAssertFalse(html.contains("onload="), "inline handlers removed")
        XCTAssertFalse(html.contains("onclick="), "inline handlers removed")
        XCTAssertFalse(html.contains("srcset="), "srcset dropped")
        XCTAssertFalse(html.contains("rel=\"preload\""), "preload hints dropped")
        XCTAssertTrue(html.contains("Content-Security-Policy"), "CSP injected")
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("<style>body{color:red} .hero{background:url(data:image/png;base64,"), "stylesheet inlined with nested url() as data URI")
        XCTAssertTrue(html.contains("src=\"data:image/jpeg;base64,"), "img inlined")
        XCTAssertTrue(html.contains("href=\"https://fieldnotes.example/guides/related/filters.html\""), "relative links absolutised")
        XCTAssertTrue(html.contains("<style>body { background: url(data:image/png;base64,"), "inline <style> url() inlined")
        XCTAssertEqual(capture.title, "Water purification in the field – Field Notes")
        XCTAssertTrue(capture.text.contains("rolling boil"))
        let urls = await fetched.urls
        XCTAssertTrue(urls.contains("https://fieldnotes.example/static/site.css"))
        XCTAssertFalse(urls.contains { $0.contains("tracker.example.com") || $0.contains("ads.example.com") }, "no tracker requests were made")
        XCTAssertEqual(capture.assetCount, 4) // css, hero.png, bg.png, boil.jpg
    }

    actor FetchLog { var urls: [String] = []; func add(_ u: String) { urls.append(u) } }
}
