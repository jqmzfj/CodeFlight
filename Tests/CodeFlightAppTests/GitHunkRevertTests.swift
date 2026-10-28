import XCTest
@testable import CodeFlightApp

final class GitHunkRevertTests: XCTestCase {
    private var workspace: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    @MainActor
    private func fixture(file: String = "file.txt", content: String) async throws -> URL {
        let root = workspace.appendingPathComponent(".git-hunk-revert-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let location = root.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: location)
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && git add . && git commit -qm original", cwd: root.path)
        guard setup.status == 0 else {
            try? FileManager.default.removeItem(at: root)
            throw NSError(domain: "HunkRevertFixture", code: Int(setup.status), userInfo: [NSLocalizedDescriptionKey: setup.output])
        }
        return root
    }

    @MainActor
    func testHunkRevertPreservesStagedContentAndOtherHunksWithLiteralFilename() async throws {
        let filename = "literal [1]\nname.txt"
        let original = (1...45).map { "line \($0)" }
        let root = try await fixture(file: filename, content: original.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(filename)
        var staged = original; staged[20] = "keep staged"
        try Data((staged.joined(separator: "\n") + "\n").utf8).write(to: file)
        let added = await CommandRunner.run(command: "git --literal-pathspecs add -- \(Shell.quote(filename))", cwd: root.path)
        XCTAssertEqual(added.status, 0, added.output)
        var working = staged; working[3] = "discard first hunk"; working[38] = "keep second hunk"
        try Data((working.joined(separator: "\n") + "\n").utf8).write(to: file)
        let beforeIndex = await CommandRunner.run(command: "git ls-files --stage -z", cwd: root.path)
        let diff = await GitService.diff(filename, at: root.path)
        XCTAssertEqual(GitDiffDocument(diff).hunks.count, 2)
        let reverted = await GitService.discardWorktreeHunk(file: filename, hunk: 0, expectedDiff: diff, at: root.path)
        XCTAssertEqual(reverted.status, 0, reverted.output)
        working[3] = staged[3]
        XCTAssertEqual(try String(contentsOf: file), working.joined(separator: "\n") + "\n")
        let afterIndex = await CommandRunner.run(command: "git ls-files --stage -z", cwd: root.path)
        XCTAssertEqual(afterIndex.output, beforeIndex.output)
        let remaining = await GitService.diff(filename, at: root.path)
        XCTAssertEqual(GitDiffDocument(remaining).hunks.count, 1)
        XCTAssertTrue(remaining.contains("keep second hunk"))
        let stale = await GitService.discardWorktreeHunk(file: filename, hunk: 1, expectedDiff: diff, at: root.path)
        XCTAssertNotEqual(stale.status, 0)
        XCTAssertEqual(try String(contentsOf: file), working.joined(separator: "\n") + "\n")
    }

    @MainActor
    func testHunkRevertFromSubdirectoryPreservesCRLFAndMissingFinalNewline() async throws {
        let original = "first\r\nsecond\r\nlast"
        let root = try await fixture(file: "nested/child.txt", content: original)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("nested/child.txt")
        try Data("first\r\nchanged\r\nlast".utf8).write(to: file)
        let cwd = root.appendingPathComponent("nested").path
        let diff = await GitService.diff("child.txt", at: cwd)
        XCTAssertTrue(GitDiffDocument(diff).supportsPartialIndex, String(reflecting: diff))
        let reverted = await GitService.discardWorktreeHunk(file: "child.txt", hunk: 0, expectedDiff: diff, at: cwd)
        XCTAssertEqual(reverted.status, 0, reverted.output)
        XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
        let status = await CommandRunner.run(command: "git status --porcelain", cwd: root.path)
        XCTAssertEqual(status.output, "")
    }

    @MainActor
    func testHunkRevertRejectsExternalChangesAndUnsupportedDiffWithoutWriting() async throws {
        let root = try await fixture(content: "first\nsecond\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        try Data("changed\nsecond\n".utf8).write(to: file)
        let diff = await GitService.diff("file.txt", at: root.path)
        try Data("external edits\nsecond\n".utf8).write(to: file)
        let stale = await GitService.discardWorktreeHunk(file: "file.txt", hunk: 0, expectedDiff: diff, at: root.path)
        XCTAssertNotEqual(stale.status, 0)
        XCTAssertEqual(try String(contentsOf: file), "external edits\nsecond\n")
        let current = await GitService.diff("file.txt", at: root.path)
        let invalid = await GitService.discardWorktreeHunk(file: "file.txt", hunk: 99, expectedDiff: current, at: root.path)
        XCTAssertNotEqual(invalid.status, 0)
        let outside = await GitService.discardWorktreeHunk(file: "../file.txt", hunk: 0, expectedDiff: current, at: root.path)
        XCTAssertNotEqual(outside.status, 0)
        let rename = await CommandRunner.run(command: "git mv file.txt renamed.txt", cwd: root.path)
        XCTAssertEqual(rename.status, 0, rename.output)
        let renamedDiff = await GitService.diff("renamed.txt", at: root.path, staged: true)
        let refused = await GitService.discardWorktreeHunk(file: "renamed.txt", hunk: 0, expectedDiff: renamedDiff, at: root.path)
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("renamed.txt")), "external edits\nsecond\n")
    }

    @MainActor
    func testHunkRevertInsertionDeletionAndFinalNewlineBoundaries() async throws {
        for (original, working) in [
            ("first\nlast\n", "inserted\nfirst\nlast\n"),
            ("first\nlast\n", "first\nlast\nappended\n"),
            ("first\nlast\n", ""),
            ("first\nlast", "first\nlast\nappended"),
            ("only line", "replacement\n"),
            ("first\r\nsecond\r\nlast", "first\r\nreplacement\r\nlast")
        ] {
            let root = try await fixture(content: original)
            defer { try? FileManager.default.removeItem(at: root) }
            _ = await CommandRunner.run(command: "git config core.autocrlf false", cwd: root.path)
            // Re-stage the raw baseline for the CRLF case.
            _ = await CommandRunner.run(command: "git add file.txt && git commit --allow-empty -qm raw-baseline", cwd: root.path)
            let file = root.appendingPathComponent("file.txt")
            try Data(working.utf8).write(to: file)
            let diff = await GitService.diff("file.txt", at: root.path)
            XCTAssertEqual(GitDiffDocument(diff).hunks.count, 1, diff)
            let reverted = await GitService.discardWorktreeHunk(file: "file.txt", hunk: 0, expectedDiff: diff, at: root.path)
            XCTAssertEqual(reverted.status, 0, reverted.output + String(reflecting: working))
            XCTAssertEqual(try Data(contentsOf: file), Data(original.utf8))
        }
    }

    @MainActor
    func testHunkRevertRefusesMixedLineEndingsAndContentFilters() async throws {
        let root = try await fixture(content: "one\ntwo\nthree\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        let working = "one\r\nchanged\nthree\r\n"
        try Data(working.utf8).write(to: file)
        let diff = await GitService.diff("file.txt", at: root.path)
        let mixed = await GitService.discardWorktreeHunk(file: "file.txt", hunk: 0, expectedDiff: diff, at: root.path)
        XCTAssertNotEqual(mixed.status, 0)
        XCTAssertEqual(try String(contentsOf: file), working)
        try Data("changed\ntwo\nthree\n".utf8).write(to: file)
        try Data("file.txt filter=custom\n".utf8).write(to: root.appendingPathComponent(".gitattributes"))
        let filteredDiff = await GitService.diff("file.txt", at: root.path)
        let filtered = await GitService.discardWorktreeHunk(file: "file.txt", hunk: 0, expectedDiff: filteredDiff, at: root.path)
        XCTAssertNotEqual(filtered.status, 0)
        XCTAssertTrue(filtered.output.contains("content filters"), filtered.output)
        XCTAssertEqual(try String(contentsOf: file), "changed\ntwo\nthree\n")
    }
}
