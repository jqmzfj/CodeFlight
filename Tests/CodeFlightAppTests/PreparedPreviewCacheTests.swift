import XCTest
@testable import CodeFlightApp

final class PreparedPreviewCacheTests: XCTestCase {
    func testRevisitReusesPreparationButChangedSourceAndFontDoNot() async throws {
        let cache = PreparedPreviewCache()
        let source = "let 中文 = 1\r\nsecond"
        let firstResult = await cache.document(file: "a", source: source, fontName: "Menlo", cellWidth: 8)
        let first = try XCTUnwrap(firstResult)
        let otherResult = await cache.document(file: "b", source: "other", fontName: "Menlo", cellWidth: 8)
        let other = try XCTUnwrap(otherResult)
        let revisitResult = await cache.document(file: "a", source: source, fontName: "Menlo", cellWidth: 8)
        let revisit = try XCTUnwrap(revisitResult)
        XCTAssertEqual(first.id, revisit.id)
        XCTAssertNotEqual(first.id, other.id)
        XCTAssertEqual(revisit.text, "let 中文 = 1\nsecond")
        let changedResult = await cache.document(file: "a", source: source + "!", fontName: "Menlo", cellWidth: 8)
        let changed = try XCTUnwrap(changedResult)
        XCTAssertNotEqual(changed.id, first.id)
        XCTAssertEqual(changed.text, "let 中文 = 1\nsecond!")
        let fontResult = await cache.document(file: "a", source: source + "!", fontName: "Monaco", cellWidth: 8)
        let font = try XCTUnwrap(fontResult)
        let widthResult = await cache.document(file: "a", source: source + "!", fontName: "Monaco", cellWidth: 10)
        let width = try XCTUnwrap(widthResult)
        XCTAssertNotEqual(font.id, changed.id)
        XCTAssertNotEqual(width.id, font.id)
        let largerResult = await cache.document(file: "a", source: source + "!", fontName: "Monaco", cellWidth: 10, fontSize: 17)
        let larger = try XCTUnwrap(largerResult)
        XCTAssertNotEqual(larger.id, width.id)
        XCTAssertEqual(larger.fontSize, 17)
        XCTAssertGreaterThan(larger.lineHeight, width.lineHeight)
    }

    func testLeastRecentlyUsedAndByteBudgetEvictWithoutBreakingPreview() async throws {
        let cache = PreparedPreviewCache(capacity: 2_000, maximumEntries: 2)
        let aResult = await cache.document(file: "a", source: "a", fontName: "Menlo", cellWidth: 8)
        let a = try XCTUnwrap(aResult)
        let bResult = await cache.document(file: "b", source: "b", fontName: "Menlo", cellWidth: 8)
        let b = try XCTUnwrap(bResult)
        let touched = await cache.document(file: "a", source: "a", fontName: "Menlo", cellWidth: 8)
        XCTAssertEqual(touched?.id, a.id)
        _ = await cache.document(file: "c", source: "c", fontName: "Menlo", cellWidth: 8)
        let retained = await cache.document(file: "a", source: "a", fontName: "Menlo", cellWidth: 8)
        XCTAssertEqual(retained?.id, a.id)
        let evicted = await cache.document(file: "b", source: "b", fontName: "Menlo", cellWidth: 8)
        XCTAssertNotEqual(evicted?.id, b.id)

        // Fits alone but not alongside another entry: exercise byte eviction
        // independently of the two-entry limit.
        let largeSource = String(repeating: "x", count: 250)
        let large = await cache.document(file: "large", source: largeSource, fontName: "Menlo", cellWidth: 8)
        XCTAssertEqual(large?.text, largeSource)
        let afterBudgetEviction = await cache.document(file: "b", source: "b", fontName: "Menlo", cellWidth: 8)
        XCTAssertNotEqual(afterBudgetEviction?.id, evicted?.id)
        let oversizedSource = String(repeating: "x", count: 1_000)
        let oversized = await cache.document(file: "huge", source: oversizedSource, fontName: "Menlo", cellWidth: 8)
        let again = await cache.document(file: "huge", source: oversizedSource, fontName: "Menlo", cellWidth: 8)
        XCTAssertEqual(oversized?.text, oversizedSource)
        XCTAssertNotEqual(oversized?.id, again?.id, "Oversized previews display normally but must not occupy the cache")
    }

    func testCancelledOwnerDoesNotPublishOrReplaceCachedDocument() async throws {
        let cache = PreparedPreviewCache()
        let original = await cache.document(file: "a", source: "original", fontName: "Menlo", cellWidth: 8)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.document(file: "a", source: "changed", fontName: "Menlo", cellWidth: 8)
        }
        let result = await cancelled.value
        XCTAssertNil(result)
        let retained = await cache.document(file: "a", source: "original", fontName: "Menlo", cellWidth: 8)
        XCTAssertEqual(original?.id, retained?.id)
    }

    func testCancellingLargePreparationDoesNotCancelAnotherFile() async throws {
        let cache = PreparedPreviewCache()
        let source = String(repeating: "\t中文🙂 long line\n", count: 100_000)
        let large = Task { await cache.document(file: "large", source: source, fontName: "Menlo", cellWidth: 8) }
        try await Task.sleep(nanoseconds: 20_000_000)
        large.cancel()
        let small = await cache.document(file: "small", source: "still usable", fontName: "Menlo", cellWidth: 8)
        let cancelledResult = await large.value
        XCTAssertNil(cancelledResult)
        XCTAssertEqual(small?.text, "still usable")
        let revisit = await cache.document(file: "small", source: "still usable", fontName: "Menlo", cellWidth: 8)
        XCTAssertEqual(revisit?.id, small?.id)
    }
}
