import XCTest
@testable import CodeFlightApp

final class FileSearchNavigationTests: XCTestCase {
    func testForwardBackwardWrapAndNonOverlappingRanges() {
        let input = FileSearchRequest(content: "aaaaa", query: "aa")
        XCTAssertEqual(FileSearchNavigator.find(input, selection: NSRange(location: 0, length: 0), direction: .next), NSRange(location: 0, length: 2))
        XCTAssertEqual(FileSearchNavigator.find(input, selection: NSRange(location: 0, length: 2), direction: .next), NSRange(location: 2, length: 2))
        XCTAssertEqual(FileSearchNavigator.find(input, selection: NSRange(location: 2, length: 2), direction: .next), NSRange(location: 0, length: 2))
        XCTAssertEqual(FileSearchNavigator.find(input, selection: NSRange(location: 0, length: 2), direction: .previous), NSRange(location: 2, length: 2))
        XCTAssertEqual(FileSearchNavigator.find(input, selection: NSRange(location: 2, length: 2), direction: .previous), NSRange(location: 0, length: 2))
    }
    func testUnicodeCaseAndMissingMatch() {
        let input = FileSearchRequest(content: "🙂 Value\nVALUE", query: "value")
        XCTAssertEqual(FileSearchNavigator.find(input, selection: NSRange(location: 0, length: 0), direction: .next), NSRange(location: 3, length: 5))
        XCTAssertEqual(FileSearchNavigator.find(input, selection: NSRange(location: 3, length: 5), direction: .previous), NSRange(location: 9, length: 5))
        XCTAssertNil(FileSearchNavigator.find(.init(content: "hello", query: "missing"), selection: NSRange(location: 0, length: 0), direction: .next))
    }
    func testCancelledScanDoesNotReturnRange() async {
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            return FileSearchNavigator.find(.init(content: "value", query: "value"), selection: NSRange(location: 0, length: 0), direction: .next)
        }
        task.cancel()
        let value = await task.value
        XCTAssertNil(value)
    }
}
