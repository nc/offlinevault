import XCTest
@testable import OfflineVaultCore

final class SubtitleTests: XCTestCase {
    func testParsesYouTubeStyleVTTAndDedupes() {
        let cues = SubtitleParser.parse(Fixtures.string("sample.vtt"))
        XCTAssertEqual(cues.map(\.text), [
            "so today we're going to talk about purifying water",
            "First, bring the water to a rolling boil for one full minute.",
            "Second, if you cannot boil, use two drops of bleach per litre and wait half an hour.",
            "Finally, a 0.2 micron filter removes bacteria but not viruses.",
        ])
        XCTAssertEqual(cues[0].start, 1.0)
        XCTAssertEqual(cues[1].start, 8.0)
        XCTAssertEqual(cues[2].start, 45.0)
    }

    func testParsesSRT() {
        let srt = "1\n00:00:01,000 --> 00:00:03,000\nHello there\n\n2\n01:02:03,500 --> 01:02:04,000\nSecond <i>line</i>\n"
        let cues = SubtitleParser.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[1].start, 3723.5)
        XCTAssertEqual(cues[1].text, "Second line")
    }

    func testWindowsGroupByTime() {
        let cues = SubtitleParser.parse(Fixtures.string("sample.vtt"))
        let w = SubtitleParser.windows(cues, windowSeconds: 30)
        XCTAssertEqual(w.count, 3)
        XCTAssertEqual(w[0].start, 1.0)
        XCTAssertTrue(w[0].text.contains("rolling boil"))
        XCTAssertEqual(w[1].start, 45.0)
    }
}
