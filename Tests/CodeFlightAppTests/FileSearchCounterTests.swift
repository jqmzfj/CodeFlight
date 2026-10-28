import XCTest
@testable import CodeFlightApp

final class FileSearchCounterTests: XCTestCase {
    func testCountsOccurrencesWithSameCaseAndOverlapRulesAsHighlighting() {
        XCTAssertEqual(FileSearchCounter.count(.init(content: "Value value\nVALUE\r\nvalue", query: "value")), 4)
        XCTAssertEqual(FileSearchCounter.count(.init(content: "aaaaa", query: "aa")), 2)
        XCTAssertEqual(FileSearchCounter.count(.init(content: "🙂值🙂值\n值", query: "🙂值")), 2)
        XCTAssertEqual(FileSearchCounter.count(.init(content: "hello\nworld", query: "missing")), 0)
        XCTAssertEqual(FileSearchCounter.count(.init(content: " \t\n", query: " \t")), 0)
        XCTAssertEqual(FileSearchCounter.count(.init(content: "", query: "value")), 0)
    }

    func testRapidQueryReplacementCancelsOldCountWithoutReplacingLatestResult() async {
        let source = String(repeating: "value value\n", count: 100_000)
        let old = Task { await FileSearchCounter.result(for: .init(content: source, query: "value")) }
        old.cancel()
        let latest = await FileSearchCounter.result(for: .init(content: source, query: "missing"))
        let cancelled = await old.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(latest, 0)
    }
}
