import XCTest
@testable import CodeFlightApp

final class RunOutputStreamTests: XCTestCase {
    func testSplitANSIProgressHyperlinksAndBackspaceProduceReadableLog() {
        let source = "start\n\u{1B}[31m红\u{1B}[0m\n10%\r20%\r100%\u{1B}[K\n\u{1B}]8;;https://example.com\u{7}link\u{1B}]8;;\u{7}\nab\u{8}c\n"
        let expected = "start\n红\n100%\nlink\nac\n"
        let scalars = Array(source.unicodeScalars)
        for split in 0...scalars.count {
            var buffer = RunLogBuffer()
            buffer.append(String(String.UnicodeScalarView(scalars[..<split])))
            buffer.append(String(String.UnicodeScalarView(scalars[split...])))
            XCTAssertEqual(buffer.snapshot.text, expected, "split \(split)")
        }
        var buffer = RunLogBuffer()
        buffer.append("a\r\nb\r\nc\u{1B}]window title\u{1B}\\d")
        XCTAssertEqual(buffer.snapshot.text, "a\nb\ncd")
    }

    func testLargeUnicodeOutputIsBoundedAndClearRetainsEscapeParserState() {
        var buffer = RunLogBuffer(limit: 100)
        buffer.append(String(repeating: "中文🚀\n", count: 10_000))
        XCTAssertTrue(buffer.snapshot.truncated)
        XCTAssertLessThanOrEqual(buffer.snapshot.text.unicodeScalars.count, 100)
        XCTAssertTrue(buffer.snapshot.text.hasSuffix("中文🚀\n"))
        buffer.append("\u{1B}[31")
        buffer.clear()
        buffer.append("mnew")
        XCTAssertEqual(buffer.snapshot.text, "new")
        XCTAssertFalse(buffer.snapshot.truncated)
    }

    @MainActor
    func testBurstCoalescesRefreshAndQueuedRefreshCannotResurrectClearedOrFinishedLog() async throws {
        var deliveries: [RunOutputSnapshot] = []
        let stream = RunOutputStream { deliveries.append($0) }
        for _ in 0..<10_000 { stream.append("discard\n") }
        stream.clear(); stream.append("keep")
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(deliveries.count, 1, "A burst should produce one queued UI refresh")
        XCTAssertEqual(deliveries.last?.text, "keep")
        stream.append(" last")
        let final = stream.finish(fallback: "must-not-replace-stream")
        stream.append("must-not-appear")
        XCTAssertEqual(final.text, "keep last")
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(deliveries.count, 1, "Queued callbacks must not update a finished session")
    }
}
