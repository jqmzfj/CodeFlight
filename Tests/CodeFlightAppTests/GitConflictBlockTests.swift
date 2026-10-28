import XCTest
@testable import CodeFlightApp

final class GitConflictBlockTests: XCTestCase {
    func testBlockChoicesPreserveUnrelatedTextAndRejectStaleDraft() throws {
        let input = "header\n<<<<<<< HEAD\nours one\n=======\ntheirs one\n>>>>>>> topic\nbetween\n<<<<<<< HEAD\nours two\n=======\ntheirs two\n>>>>>>> topic\nfooter"
        let blocks = GitConflictBlocks.parse(input)
        XCTAssertEqual(blocks.count, 2)
        let first = try XCTUnwrap(blocks.first)
        XCTAssertEqual(first.ours, "ours one\n")
        XCTAssertEqual(first.theirs, "theirs one\n")
        XCTAssertNil(GitConflictBlocks.replacing(first, choice: .ours, in: input + "modified", expected: input))
        let partial = try XCTUnwrap(GitConflictBlocks.replacing(first, choice: .ours, in: input, expected: input))
        XCTAssertTrue(partial.hasPrefix("header\nours one\nbetween\n"))
        let remaining = try XCTUnwrap(GitConflictBlocks.parse(partial).first)
        let final = try XCTUnwrap(GitConflictBlocks.replacing(remaining, choice: .theirs, in: partial, expected: partial))
        XCTAssertEqual(final, "header\nours one\nbetween\ntheirs two\nfooter")
        XCTAssertFalse(GitService.containsConflictMarkers(final))
    }

    func testDiff3CustomMarkersPreserveUnicodeAndCRLF() throws {
        let input = "前言\r\n<<<<<<<<<< ours\r\n当前🙂\r\n|||||||||| base\r\n祖先\r\n==========\r\n传入\r\n>>>>>>>>>> theirs\r\n结束\r\n"
        let block = try XCTUnwrap(GitConflictBlocks.parse(input).first)
        XCTAssertEqual(block.ours, "当前🙂\r\n")
        XCTAssertEqual(block.base, "祖先\r\n")
        XCTAssertEqual(block.theirs, "传入\r\n")
        XCTAssertTrue(GitService.containsConflictMarkers(input))
        let final = GitConflictBlocks.replacing(block, choice: .oursThenTheirs, in: input, expected: input)
        XCTAssertEqual(final, "前言\r\n当前🙂\r\n传入\r\n结束\r\n")
    }

    func testMalformedAndNestedMarkersDoNotOfferAutomaticReplacement() {
        for input in [
            "<<<<<<< HEAD\nours\n=======\ntheirs\n",
            "<<<<<<< HEAD\nours\n========\ntheirs\n>>>>>>> topic\n",
            "<<<<<<< HEAD\n<<<<<<< nested\nours\n=======\ntheirs\n>>>>>>> topic\n",
            "<<<<<<< HEAD\nours\n>>>>>>> topic\n"
        ] {
            XCTAssertTrue(GitConflictBlocks.parse(input).isEmpty, input)
            XCTAssertTrue(GitService.containsConflictMarkers(input), input)
        }
        XCTAssertFalse(GitService.containsConflictMarkers("a <<<<<<< comparison\n========heading\n>>>>>>>identifier"))
        XCTAssertTrue(GitConflictBlocks.parse("ordinary text").isEmpty)
    }

    func testEmptySidesAndBothOrdersWithUnterminatedEndMarker() throws {
        let input = "<<<<<<< ours\n=======\nnew line\n>>>>>>> theirs"
        let block = try XCTUnwrap(GitConflictBlocks.parse(input).first)
        XCTAssertEqual(block.ours, "")
        XCTAssertEqual(GitConflictBlocks.replacing(block, choice: .ours, in: input, expected: input), "")
        XCTAssertEqual(GitConflictBlocks.replacing(block, choice: .theirsThenOurs, in: input, expected: input), "new line\n")
        let two = "<<<<<<< ours\nfirst\n=======\nsecond\n>>>>>>> theirs\n"
        let other = try XCTUnwrap(GitConflictBlocks.parse(two).first)
        XCTAssertEqual(GitConflictBlocks.replacing(other, choice: .theirsThenOurs, in: two, expected: two), "second\nfirst\n")
    }

    @MainActor
    func testMixedBlockResolutionSavesOnlyChosenFileAndKeepsAutomaticMerge() async throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".git-conflict-block-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.swift")
        let original = (1...40).map { "let line\($0) = \($0)" }
        try Data((original.joined(separator: "\n") + "\n").utf8).write(to: file)
        try Data("keep".utf8).write(to: root.appendingPathComponent("other.txt"))
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && git add . && git commit -qm base && git branch topic", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        var ours = original
        ours[3] = "let line4 = 400"; ours[30] = "let line31 = 3100"
        try Data((ours.joined(separator: "\n") + "\n").utf8).write(to: file)
        let main = await CommandRunner.run(command: "git commit -qam ours && git checkout -q topic", cwd: root.path)
        XCTAssertEqual(main.status, 0, main.output)
        var theirs = original
        theirs[3] = "let line4 = 401"; theirs[30] = "let line31 = 3101"; theirs[20] = "let automatic = true"
        try Data((theirs.joined(separator: "\n") + "\n").utf8).write(to: file)
        let merge = await CommandRunner.run(command: "git commit -qam theirs && git checkout -q main && git merge --no-edit topic", cwd: root.path)
        XCTAssertNotEqual(merge.status, 0)
        try Data("local unstaged".utf8).write(to: root.appendingPathComponent("other.txt"))
        let snapshot = await GitService.conflictSnapshot("file.swift", at: root.path)
        XCTAssertTrue(snapshot.editable)
        let blocks = GitConflictBlocks.parse(snapshot.working)
        XCTAssertEqual(blocks.count, 2)
        let first = try XCTUnwrap(blocks.first)
        let partial = try XCTUnwrap(GitConflictBlocks.replacing(first, choice: .ours, in: snapshot.working, expected: snapshot.working))
        let second = try XCTUnwrap(GitConflictBlocks.parse(partial).first)
        let final = try XCTUnwrap(GitConflictBlocks.replacing(second, choice: .theirs, in: partial, expected: partial))
        var expected = original
        expected[3] = ours[3]; expected[30] = theirs[30]; expected[20] = theirs[20]
        XCTAssertEqual(final, expected.joined(separator: "\n") + "\n")
        let saved = await GitService.saveConflict("file.swift", result: final, snapshot: snapshot, at: root.path)
        XCTAssertEqual(saved.status, 0, saved.output)
        XCTAssertEqual(try String(contentsOf: file), final)
        let index = await CommandRunner.run(command: "git show :file.swift", cwd: root.path)
        XCTAssertEqual(index.output, final)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("other.txt")), "local unstaged")
        let unrelatedIndex = await CommandRunner.run(command: "git show :other.txt", cwd: root.path)
        XCTAssertEqual(unrelatedIndex.output, "keep")
    }
}
