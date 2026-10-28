import XCTest
@testable import CodeFlightApp

@MainActor
final class PreviewTraceTests: XCTestCase {
    func testMilestonesProduceOneSampleWithoutRecordingFullPath() {
        var clock: UInt64 = 10_000_000
        var samples: [PreviewTrace.Sample] = []
        let trace = PreviewTrace(now: { clock }, resident: { 12 }, peak: { 30 }, sink: { samples.append($0) })
        let document = UUID()
        trace.begin(file: "/private/fixture/large.swift")
        clock += 2_000_000; trace.didRead(file: "/private/fixture/large.swift")
        clock += 3_000_000; trace.didPrepare(file: "/private/fixture/large.swift", document: document)
        clock += 4_000_000; trace.didDraw(document: document)
        trace.didDraw(document: document)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].file, "large.swift")
        XCTAssertEqual(samples[0].handlerToReadMS, 2)
        XCTAssertEqual(samples[0].handlerToPreparedMS, 5)
        XCTAssertEqual(samples[0].handlerToDrawMS, 9)
        XCTAssertEqual(samples[0].drawResidentMB, 12)
        XCTAssertEqual(samples[0].processLifetimePeakMB, 30)
    }

    func testSupersededAndCancelledDocumentsCannotCompleteAnotherOpen() {
        var samples: [PreviewTrace.Sample] = []
        let trace = PreviewTrace(sink: { samples.append($0) })
        let first = UUID(); let second = UUID()
        trace.begin(file: "/first.swift"); trace.didRead(file: "/first.swift")
        trace.didPrepare(file: "/first.swift", document: first)
        trace.begin(file: "/second.swift")
        trace.didRead(file: "/first.swift"); trace.didPrepare(file: "/first.swift", document: first)
        trace.didDraw(document: first)
        // An old retained preview must not bind before the new read completes.
        trace.didPrepare(file: "/second.swift", document: first)
        trace.didDraw(document: first)
        XCTAssertTrue(samples.isEmpty)
        trace.didRead(file: "/second.swift")
        trace.didPrepare(file: "/second.swift", document: second)
        trace.didDraw(document: first)
        XCTAssertTrue(samples.isEmpty)
        trace.cancel(); trace.didDraw(document: second)
        XCTAssertTrue(samples.isEmpty)
    }
}
