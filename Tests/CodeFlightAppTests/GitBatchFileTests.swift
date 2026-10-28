import XCTest
@testable import CodeFlightApp

final class GitBatchFileTests: XCTestCase {
    @MainActor private func fixture(commit: Bool = true) async throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".git-batch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com", cwd: root.path)
        if commit {
            for name in ["one.txt", "two [1].txt", "keep.txt"] { try "initial\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
            let initial = await CommandRunner.run(command: "git add . && git commit -qm initial", cwd: root.path)
            XCTAssertEqual(initial.status, 0, initial.output)
        }
        return root
    }
    private func write(_ value: String, _ file: String, _ root: URL) throws { try value.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8) }

    @MainActor func testStageAndUnstageOnlySelectedFilesIncludingLiteralPaths() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one changed\n", "one.txt", root)
        try write("two changed\n", "two [1].txt", root)
        try write("keep changed\n", "keep.txt", root)
        try write("new\n", "--new\n文件.txt", root)
        let before = await GitService.status(at: root.path)
        let selected = before.changes.filter { $0.path != "keep.txt" }
        let stage = await GitService.batchFileAction(.stage, changes: selected, at: root.path)
        XCTAssertEqual(stage.status, 0, stage.output)
        let staged = await GitService.status(at: root.path)
        XCTAssertEqual(Set(staged.changes.filter(\.isStaged).map(\.path)), Set(selected.map(\.path)))
        XCTAssertFalse(staged.changes.first { $0.path == "keep.txt" }!.isStaged)
        let unstage = await GitService.batchFileAction(.unstage, changes: staged.changes.filter(\.isStaged), at: root.path)
        XCTAssertEqual(unstage.status, 0, unstage.output)
        let after = await GitService.status(at: root.path)
        XCTAssertTrue(after.changes.allSatisfy { !$0.isStaged })
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("two [1].txt")), "two changed\n")
    }

    @MainActor func testUnbornUnstageAndRenameKeepWorktree() async throws {
        let root = try await fixture(commit: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try write("new one\n", "a.txt", root); try write("new two\n", "b.txt", root)
        let initial = await GitService.status(at: root.path)
        let stage = await GitService.batchFileAction(.stage, changes: initial.changes, at: root.path)
        XCTAssertEqual(stage.status, 0, stage.output)
        try write("working one\n", "a.txt", root)
        let staged = await GitService.status(at: root.path)
        let unstage = await GitService.batchFileAction(.unstage, changes: staged.changes, at: root.path)
        XCTAssertEqual(unstage.status, 0, unstage.output)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.txt")), "working one\n")
        _ = await CommandRunner.run(command: "git add . && git commit -qm initial && git mv a.txt 'renamed [1].txt'", cwd: root.path)
        let renameStatus = await GitService.status(at: root.path)
        let renamed = try XCTUnwrap(renameStatus.changes.first)
        XCTAssertEqual(renamed.originalPath, "a.txt")
        let restored = await GitService.batchFileAction(.unstage, changes: [renamed], at: root.path)
        XCTAssertEqual(restored.status, 0, restored.output)
        let index = await CommandRunner.run(command: "git diff --cached --name-only", cwd: root.path)
        XCTAssertTrue(index.output.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed [1].txt").path))
    }

    @MainActor func testRollbackSelectedWorktreePreservesStagedVersionAndUnselectedFiles() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("staged\n", "one.txt", root)
        _ = await CommandRunner.run(command: "git add one.txt", cwd: root.path)
        try write("working\n", "one.txt", root)
        try write("working two\n", "two [1].txt", root)
        try write("keep working\n", "keep.txt", root)
        try write("untracked\n", "new [1].txt", root)
        try write("keep new\n", "new 1.txt", root)
        let status = await GitService.status(at: root.path)
        let selected = status.changes.filter { ["one.txt", "two [1].txt", "new [1].txt"].contains($0.path) }
        let result = await GitService.batchFileAction(.discard, changes: selected, at: root.path)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("one.txt")), "staged\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("two [1].txt")), "initial\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("keep.txt")), "keep working\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("new 1.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new [1].txt").path))
        let index = await CommandRunner.run(command: "git show :one.txt", cwd: root.path)
        XCTAssertEqual(index.output, "staged\n")
    }

    @MainActor func testStaleSelectionRejectsWholeBatchBeforeAnyMutation() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("changed\n", "one.txt", root); try write("changed two\n", "two [1].txt", root)
        let snapshot = await GitService.status(at: root.path)
        _ = await CommandRunner.run(command: "git add one.txt", cwd: root.path)
        let before = await CommandRunner.run(command: "git diff --cached --binary && git diff --binary", cwd: root.path)
        for action in [GitFileAction.stage, .unstage, .discard] {
            let result = await GitService.batchFileAction(action, changes: snapshot.changes, at: root.path)
            XCTAssertNotEqual(result.status, 0)
        }
        let after = await CommandRunner.run(command: "git diff --cached --binary && git diff --binary", cwd: root.path)
        XCTAssertEqual(before.output, after.output)
        let empty = await GitService.batchFileAction(.stage, changes: [], at: root.path)
        XCTAssertNotEqual(empty.status, 0)
    }

    @MainActor func testConflictsRejectEntireSelection() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git switch -qc incoming && printf incoming > one.txt && git commit -qam incoming && git switch -q main && printf main > one.txt && git commit -qam main && git merge incoming", cwd: root.path)
        try write("unrelated\n", "keep.txt", root)
        let status = await GitService.status(at: root.path)
        XCTAssertTrue(status.changes.contains(where: \.isConflicted))
        for action in [GitFileAction.stage, .unstage, .discard] {
            let result = await GitService.batchFileAction(action, changes: status.changes, at: root.path)
            XCTAssertNotEqual(result.status, 0)
        }
        let after = await GitService.status(at: root.path)
        XCTAssertTrue(after.changes.contains(where: \.isConflicted))
        XCTAssertFalse(after.changes.first { $0.path == "keep.txt" }!.isStaged)
    }
    @MainActor func testSubmoduleRollbackRejectsBeforeRestoringOtherFiles() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "git clone -q . nested && git add nested && git commit -qm gitlink", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        try write("parent dirty\n", "one.txt", root)
        try write("nested dirty\n", "nested/one.txt", root)
        let status = await GitService.status(at: root.path)
        XCTAssertTrue(status.changes.contains { $0.path == "nested" })
        let result = await GitService.batchFileAction(.discard, changes: status.changes, at: root.path)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("one.txt")), "parent dirty\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("nested/one.txt")), "nested dirty\n")
    }

    @MainActor func testStageLocalEditAfterStagedRename() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git mv one.txt 'renamed [1].txt'", cwd: root.path)
        try write("edited after rename\n", "renamed [1].txt", root)
        let snapshot = await GitService.status(at: root.path)
        let renamed = try XCTUnwrap(snapshot.changes.first { $0.path == "renamed [1].txt" })
        XCTAssertEqual(renamed.state, "RM")
        let result = await GitService.batchFileAction(.stage, changes: [renamed], at: root.path)
        XCTAssertEqual(result.status, 0, result.output)
        let index = await CommandRunner.run(command: "git show ':renamed [1].txt'", cwd: root.path)
        XCTAssertEqual(index.output, "edited after rename\n")
        try write("single file stage\n", "renamed [1].txt", root)
        let single = await GitService.fileAction(.stage, path: renamed.path, at: root.path, originalPath: renamed.originalPath)
        XCTAssertEqual(single.status, 0, single.output)
        let singleIndex = await CommandRunner.run(command: "git show ':renamed [1].txt'", cwd: root.path)
        XCTAssertEqual(singleIndex.output, "single file stage\n")
    }

}
