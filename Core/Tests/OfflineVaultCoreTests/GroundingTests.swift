import XCTest
@testable import OfflineVaultCore

final class GroundingTests: XCTestCase {
    let bleach = RetrievedPassage(label: 1, source: .zimArticle(book: "fieldguide", path: "A/Water", title: "Treating water"), text: "Add 8 drops of unscented household bleach per gallon of water. Stir and let it stand for 30 minutes. If the water does not smell slightly of chlorine, repeat the dose and wait another 15 minutes.\nFor cloudy water, filter it through cloth first.", score: 1, retriever: "reference")
    let standing = RetrievedPassage(label: 2, source: .document(id: "cdc", title: "CDC water guide", page: 3), text: "Let the treated water stand for 30 minutes before drinking. Store it in clean, covered containers.", score: 1, retriever: "documents")

    func quote(_ p: RetrievedPassage, _ q: Quote) -> String { (p.text as NSString).substring(with: NSRange(q.range)) }

    func testCopiedSentenceGetsTheExactSubstringAndItsRange() {
        let g = Grounding.ground(answer: "Add 8 drops of unscented household bleach per gallon of water [1].", passages: [bleach])
        guard case .claim(let text, let quotes) = g.segments.first, quotes.count == 1 else { return XCTFail("expected one claim with one quote, got \(g.segments)") }
        XCTAssertEqual(text, "Add 8 drops of unscented household bleach per gallon of water.")
        XCTAssertEqual(quotes[0].label, 1)
        XCTAssertEqual(quotes[0].text, "Add 8 drops of unscented household bleach per gallon of water.")
        XCTAssertEqual(quote(bleach, quotes[0]), quotes[0].text, "range points at the quote inside the passage")
        XCTAssertEqual(quotes[0].score, 1, accuracy: 0.001)
    }

    func testParaphraseWithTheSameNumbersStillMatches() {
        let g = Grounding.ground(answer: "Use 8 drops of bleach for each gallon of water, then wait 30 minutes [1].", passages: [bleach])
        guard case .claim(_, let quotes) = g.segments.first, let q = quotes.first else { return XCTFail("expected a claim, got \(g.segments)") }
        XCTAssertTrue(q.text.hasPrefix("Add 8 drops"), "quote starts at the passage sentence with the dose")
        XCTAssertTrue(q.text.hasSuffix("30 minutes."), "quote extends to the sentence with the wait")
        XCTAssertEqual(quote(bleach, q), q.text)
        XCTAssertGreaterThanOrEqual(q.score, Grounding.threshold)
    }

    func testNumberAbsentFromThePassageIsUnverifiedDespiteWordOverlap() {
        let g = Grounding.ground(answer: "Add 16 drops of unscented household bleach per gallon of water [1].", passages: [bleach])
        XCTAssertEqual(g.segments, [.unverified(text: "Add 16 drops of unscented household bleach per gallon of water.", citedLabels: [1])])
        XCTAssertEqual(g.unverifiedClaims, 1); XCTAssertEqual(g.supportedClaims, 0)
    }

    func testCitationToALabelNotInTheSourcesIsUnverified() {
        let g = Grounding.ground(answer: "Add 8 drops of unscented household bleach per gallon of water [3].", passages: [bleach])
        XCTAssertEqual(g.segments, [.unverified(text: "Add 8 drops of unscented household bleach per gallon of water.", citedLabels: [3])])
    }

    func testProseKeepsListNumberingAndMarkdown() {
        let answer = "**Steps:**\n1. Boil the water if you can.\n2. Add 8 drops of unscented household bleach per gallon of water [1].\n3. Wait before drinking."
        let g = Grounding.ground(answer: answer, passages: [bleach])
        XCTAssertEqual(g.segments.count, 3)
        XCTAssertEqual(g.segments[0], .prose("**Steps:**\n1. Boil the water if you can.\n2. "))
        guard case .claim(let text, _) = g.segments[1] else { return XCTFail("middle segment is the claim") }
        XCTAssertEqual(text, "Add 8 drops of unscented household bleach per gallon of water.")
        XCTAssertEqual(g.segments[2], .prose("\n3. Wait before drinking."))
    }

    func testTwoCitationsYieldTwoQuotesWhenBothSupportTheClaim() {
        let g = Grounding.ground(answer: "Let the water stand for 30 minutes [1][2].", passages: [bleach, standing])
        guard case .claim(_, let quotes) = g.segments.first else { return XCTFail("expected a claim, got \(g.segments)") }
        XCTAssertEqual(quotes.map(\.label), [1, 2])
        XCTAssertEqual(quotes[0].text, "Stir and let it stand for 30 minutes.")
        XCTAssertEqual(quotes[1].text, "Let the treated water stand for 30 minutes before drinking.")
        XCTAssertEqual(quote(standing, quotes[1]), quotes[1].text)
    }

    func testUnverifiedPrefixIsUnverifiedWithNoLabels() {
        let g = Grounding.ground(answer: "Unverified: iodine tablets also work if you have them [1].", passages: [bleach])
        XCTAssertEqual(g.segments, [.unverified(text: "Unverified: iodine tablets also work if you have them.", citedLabels: [])])
    }

    func testDecimalsDoNotSplitASentence() {
        let p = RetrievedPassage(label: 1, source: .page(id: "x", title: "Dosing", url: "https://example.org"), text: "Use 0.5 ml of the concentrate per litre. Shake well.", score: 1, retriever: "pages")
        let g = Grounding.ground(answer: "Use 0.5 ml of the concentrate per litre [1].", passages: [p])
        guard case .claim(_, let quotes) = g.segments.first else { return XCTFail("expected a claim, got \(g.segments)") }
        XCTAssertEqual(quotes.first?.text, "Use 0.5 ml of the concentrate per litre.")
    }

    func testQuoteSpansASoftWrappedLineInsteadOfStoppingMidSentence() {
        let p = RetrievedPassage(label: 1, source: .zimArticle(book: "fieldguide", path: "A/Hypothermia", title: "Hypothermia"), text: "Hypothermia\nTreatment: move the person out of wind and wet, remove wet clothing, and insulate from the\nground with anything dry. Handle severely hypothermic people gently.", score: 1, retriever: "reference")
        let g = Grounding.ground(answer: "Move the person out of wind and wet, remove wet clothing, and insulate from the ground [1].", passages: [p])
        guard case .claim(_, let quotes) = g.segments.first, let q = quotes.first else { return XCTFail("expected a claim, got \(g.segments)") }
        XCTAssertEqual(q.text, "Treatment: move the person out of wind and wet, remove wet clothing, and insulate from the\nground with anything dry.")
        XCTAssertEqual(quote(p, q), q.text)
    }

    func testShortWrappedLineAfterASentenceBreakStillJoinsTheNextLine() {
        // The fixture Field Guide wraps "Add 2 drops" onto its own line right after a sentence ends; the number must stay with its sentence.
        let p = RetrievedPassage(label: 1, source: .zimArticle(book: "fieldguide", path: "A/Water", title: "Water purification"), text: "Chemical treatment: use unscented household bleach (5–6% sodium hypochlorite). Add 2 drops\nper litre of clear water, or 4 drops per litre of cloudy water, stir and wait 30 minutes. A faint\nchlorine smell is expected; if there is none, repeat the dose and wait another 15 minutes.", score: 1, retriever: "reference")
        let g = Grounding.ground(answer: "For clear water, add 2 drops of bleach per litre and wait 30 minutes [1].", passages: [p])
        guard case .claim(_, let quotes) = g.segments.first, let q = quotes.first else { return XCTFail("expected a claim, got \(g.segments)") }
        XCTAssertTrue(q.text.hasPrefix("Add 2 drops\nper litre of clear water"), q.text)
        XCTAssertEqual(quote(p, q), q.text)
    }

    func testTwoTopicWordsDoNotVerifyAClaim() {
        let p = RetrievedPassage(label: 1, source: .document(id: "fm", title: "FM 4-25.11", page: 125), text: "The first aid measures for a casualty with severe hypothermia are based upon the following principles: attempt to avoid further heat loss, handle the casualty gently, and transport the casualty as soon as possible.", score: 1, retriever: "documents")
        let g = Grounding.ground(answer: "Rub the severely hypothermic limbs [1].", passages: [p])
        XCTAssertEqual(g.segments, [.unverified(text: "Rub the severely hypothermic limbs.", citedLabels: [1])], "half the words match but only the topic words do")
    }

    func testCountsCoverEveryClaim() {
        let answer = "Treat the water first.\n1. Add 8 drops of unscented household bleach per gallon of water [1].\n2. Let the water stand for 30 minutes [1][2].\n3. Add 16 more drops if it smells of nothing [1].\nUnverified: iodine works too.\nThen drink."
        let g = Grounding.ground(answer: answer, passages: [bleach, standing])
        XCTAssertEqual(g.supportedClaims, 2)
        XCTAssertEqual(g.unverifiedClaims, 2)
        XCTAssertEqual(g.segments.filter { if case .prose = $0 { return true }; return false }.count, 5, "prose before, between and after the claims")
    }
}
