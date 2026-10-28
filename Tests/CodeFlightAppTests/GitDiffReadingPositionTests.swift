import XCTest
@testable import CodeFlightApp

final class GitDiffReadingPositionTests: XCTestCase {
    private let source = """
    diff --git a/file b/file
    --- a/file
    +++ b/file
    @@ -3,4 +7,5 @@
     context
    -old A
    -old B
    +new A
    +new B
    +extra
     tail
    @@ -100,2 +200,0 @@
    -delete A
    -delete B
    @@ -300,0 +400,2 @@
    +add A
    +add B
    \\ No newline at end of file
    """

    func testReplacementAndUnequalInsertionsMapToActualSourceLinesAcrossModes() throws {
        let presentation = GitDiffPresentation(source)
        let replacement = try XCTUnwrap(presentation.splitRows.first { $0.location.oldLine == 4 })
        XCTAssertEqual(replacement.location.newLine, 8)
        let target = try XCTUnwrap(presentation.rowID(for: replacement.location, split: false))
        let row = try XCTUnwrap(presentation.unifiedRows.first { $0.id == target })
        guard case .unified(let line) = row.content else { return XCTFail("Expected unified source") }
        XCTAssertEqual(line, "+new A")
        let removed = try XCTUnwrap(presentation.unifiedRows.first { $0.location.oldLine == 5 })
        let paired = try XCTUnwrap(presentation.rowID(for: removed.location, split: true))
        XCTAssertEqual(presentation.splitRows.first { $0.id == paired }?.location.newLine, 9)
        let extra = try XCTUnwrap(presentation.splitRows.first { $0.location.newLine == 10 })
        XCTAssertNil(extra.location.oldLine)
        let extraTarget = try XCTUnwrap(presentation.rowID(for: extra.location, split: false))
        guard case .unified(let extraText) = presentation.unifiedRows.first(where: { $0.id == extraTarget })?.content else { return XCTFail("Expected inserted line") }
        XCTAssertEqual(extraText, "+extra")
        XCTAssertEqual(presentation.splitRows.first { $0.location.oldLine == 6 }?.location.newLine, 11)
    }

    func testPureDeletionAdditionHeadersAndNoNewlineMarkersHaveLocalAnchors() throws {
        let presentation = GitDiffPresentation(source)
        let deleted = GitDiffReadingLocation(hunk: 1, oldLine: 101, newLine: nil)
        let id = try XCTUnwrap(presentation.rowID(for: deleted, split: true))
        XCTAssertEqual(presentation.splitRows.first { $0.id == id }?.location, deleted)
        let last = try XCTUnwrap(presentation.unifiedRows.last)
        XCTAssertEqual(last.location, .init(hunk: 2, oldLine: nil, newLine: 401))
        let added = try XCTUnwrap(presentation.rowID(for: last.location, split: true))
        XCTAssertEqual(presentation.splitRows.first { $0.id == added }?.location.newLine, 401)
        let header = GitDiffReadingLocation(hunk: 1, oldLine: nil, newLine: nil)
        let headerID = try XCTUnwrap(presentation.rowID(for: header, split: false))
        XCTAssertEqual(presentation.unifiedRows.first { $0.id == headerID }?.location, header)
        XCTAssertEqual(presentation.rowID(for: .init(hunk: 1, oldLine: 999, newLine: nil), split: false), headerID)
        XCTAssertNil(presentation.rowID(for: .init(hunk: 99, oldLine: 1, newLine: 1), split: true))
    }

    func testVisibleRowReductionIgnoresOffscreenPrefetchAndKeepsModesSeparate() {
        var visible: [Bool: GitDiffVisibleRow] = [:]
        let first = GitDiffReadingLocation(hunk: 5, oldLine: 100, newLine: 110)
        let next = GitDiffReadingLocation(hunk: 5, oldLine: 101, newLine: 111)
        GitDiffVisibleRowPreference.reduce(value: &visible) { [true: .init(location: next, minY: 15, maxY: 36)] }
        GitDiffVisibleRowPreference.reduce(value: &visible) { [true: .init(location: first, minY: -6, maxY: 15)] }
        GitDiffVisibleRowPreference.reduce(value: &visible) { [true: .init(location: next, minY: -50, maxY: -29)] }
        GitDiffVisibleRowPreference.reduce(value: &visible) { [true: .init(location: next, minY: .nan, maxY: 10)] }
        GitDiffVisibleRowPreference.reduce(value: &visible) { [false: .init(location: next, minY: 0, maxY: 21)] }
        XCTAssertEqual(visible[true]?.location, first)
        XCTAssertEqual(visible[false]?.location, next)
        XCTAssertEqual(visible.count, 2)
    }
}
