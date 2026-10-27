import XCTest
@testable import Transcriberr

/// Marking a Library search in the transcript of the recording it found.
final class SearchHighlightTests: XCTestCase {
    private func found(_ q: String, _ text: String) -> [String] {
        SearchHighlight.ranges(of: q, in: text).map { (text as NSString).substring(with: $0) }
    }

    func testCaseAndAccentsAreIgnoredLikeTheLibrarySearch() {
        XCTAssertEqual(found("data so", "We need Data Sovereignty, data sources too."), ["Data So", "data so"])
        XCTAssertEqual(found("cafe", "Meet at the Café"), ["Café"])
        // What the Library's predicate finds, the marks find too.
        let text = "Over to the Data Sovereignty work package."
        XCTAssertEqual(text.localizedStandardContains("data so"), SearchHighlight.matches("data so", text))
    }

    func testEveryOccurrenceWithoutOverlap() {
        XCTAssertEqual(found("aa", "aaaa"), ["aa", "aa"])
        XCTAssertEqual(SearchHighlight.ranges(of: "um", in: "um uh um").map(\.location), [0, 6])
    }

    func testNothingToMark() {
        XCTAssertTrue(found("  ", "anything").isEmpty)
        XCTAssertTrue(found("zzz", "anything").isEmpty)
        XCTAssertTrue(found("a", "").isEmpty)
    }

    func testRangesFitAttributedText() {
        // The view turns these into AttributedString ranges; emoji and
        // accents before the match must not shift them.
        let text = "🙂 Résumé: data sovereignty"
        let attr = AttributedString(text)
        let r = try! XCTUnwrap(SearchHighlight.ranges(of: "data so", in: text).first)
        let range = try! XCTUnwrap(Range(r, in: attr))
        XCTAssertEqual(String(attr[range].characters), "data so")
    }
}
