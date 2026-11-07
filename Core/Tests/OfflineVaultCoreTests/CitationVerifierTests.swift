import XCTest
@testable import OfflineVaultCore

final class CitationVerifierTests: XCTestCase {
    let p1 = RetrievedPassage(label: 1, source: .document(id: "fm", title: "FM 4-25.11", page: 46), text: "The tourniquet should not be used unless a pressure dressing has failed to stop the bleeding. If left in place too long, a tourniquet can cause loss of an arm or leg. Once applied it must stay in place and the casualty must be taken to a medical treatment facility.", score: 1, retriever: "documents")
    let p2 = RetrievedPassage(label: 2, source: .document(id: "fm", title: "FM 4-25.11", page: 47), text: "Place the tourniquet around the limb, between the wound and the body trunk. Place the tourniquet 2 to 4 inches from the edge of the wound site. Never place it directly over a wound or a fracture or directly on a joint. The tourniquet should have padding underneath.", score: 1, retriever: "documents")

    func testRelabelsSentenceThatClearlyCamesFromAnotherPassage() {
        let answer = "1. Place the tourniquet around the thigh, between the wound and the body trunk, about 2 to 4 inches from the edge of the wound [1].\n2. Transport to the nearest medical treatment facility because leaving a tourniquet on too long can cause loss of limb [1]."
        let (fixed, corrections) = CitationVerifier.correct(answer: answer, passages: [p1, p2])
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?.from, 1); XCTAssertEqual(corrections.first?.to, 2)
        XCTAssertTrue(fixed.contains("edge of the wound [2]."))
        XCTAssertTrue(fixed.contains("loss of limb [1]."), "correctly cited sentence untouched")
    }

    func testLeavesAmbiguousOrShortSentencesAlone() {
        let answer = "Use a tourniquet [1]. Keep padding underneath and avoid joints; move to a facility soon [1][2]."
        let (fixed, corrections) = CitationVerifier.correct(answer: answer, passages: [p1, p2])
        XCTAssertTrue(corrections.isEmpty)
        XCTAssertEqual(fixed, answer)
        XCTAssertEqual(CitationVerifier.correct(answer: "Anything [1].", passages: [p1]).text, "Anything [1].", "single passage: nothing to correct")
    }
}
