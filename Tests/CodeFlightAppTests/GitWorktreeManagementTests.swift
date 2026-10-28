import XCTest
@testable import CodeFlightApp

final class GitWorktreeManagementTests: XCTestCase {
    @MainActor
    private func fixture() async throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".git-worktree-management-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf original > file.txt && git add . && git commit -qm original && git worktree add -qb linked 'child [1]'", cwd: root.path)
        guard result.status == 0 else { try? FileManager.default.removeItem(at: root); throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: result.output]) }
        return root
    }

    @MainActor
    func testLockUnlockPreservesDirtyCheckoutAndRejectsStaleReason() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child [1]")
        try "dirty".write(to: child.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let initial = await GitService.worktrees(at: root.path)
        let tree = try XCTUnwrap(initial.0.last)
        let reason = "外接磁盘 ' [1]\n$(touch injected)"
        let locked = await GitService.setWorktreeLocked(tree, locked: true, reason: reason, at: root.path)
        XCTAssertEqual(locked.status, 0, locked.output)
        let after = await GitService.worktrees(at: root.path)
        let snapshot = try XCTUnwrap(after.0.last)
        XCTAssertEqual(snapshot.locked, reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path))
        let stale = await GitService.setWorktreeLocked(tree, locked: false, reason: "", at: root.path)
        XCTAssertNotEqual(stale.status, 0)
        let removed = await GitService.removeWorktree(snapshot, at: root.path)
        XCTAssertNotEqual(removed.status, 0)
        let unlocked = await GitService.setWorktreeLocked(snapshot, locked: false, reason: "", at: root.path)
        XCTAssertEqual(unlocked.status, 0, unlocked.output)
        let final = await GitService.worktrees(at: root.path)
        XCTAssertNil(final.0.last?.locked)
        XCTAssertEqual(try String(contentsOf: child.appendingPathComponent("file.txt")), "dirty")
        let primary = await GitService.setWorktreeLocked(initial.0[0], locked: true, reason: "", at: root.path)
        XCTAssertNotEqual(primary.status, 0)
    }

    @MainActor
    func testPruneMissingCheckoutKeepsLockedRecordsExistingDirectoriesAndBranches() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git worktree add -qb offline offline && git worktree lock --reason disk offline && git worktree add -qb valid valid", cwd: root.path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("child [1]"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("offline"))
        let before = await GitService.worktrees(at: root.path)
        XCTAssertEqual(before.0.count, 4)
        XCTAssertNotNil(before.0.first { $0.branch == "refs/heads/linked" }?.prunable)
        let pruned = await GitService.pruneWorktrees(expected: before.0, at: root.path)
        XCTAssertEqual(pruned.status, 0, pruned.output)
        let after = await GitService.worktrees(at: root.path)
        XCTAssertEqual(after.0.count, 3)
        XCTAssertTrue(after.0.contains { $0.locked == "disk" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("valid/file.txt").path))
        let branch = await CommandRunner.run(command: "git show-ref --verify refs/heads/linked", cwd: root.path)
        XCTAssertEqual(branch.status, 0)
        let empty = await GitService.pruneWorktrees(expected: after.0, at: root.path)
        XCTAssertNotEqual(empty.status, 0)
    }

    @MainActor
    func testPruneRejectsChangedListAndRestoredDirectory() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = await GitService.worktrees(at: root.path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("child [1]"))
        let stale = await GitService.pruneWorktrees(expected: initial.0, at: root.path)
        XCTAssertNotEqual(stale.status, 0)
        let missing = await GitService.worktrees(at: root.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("child [1]"), withIntermediateDirectories: true)
        try "keep".write(to: root.appendingPathComponent("child [1]/keep.txt"), atomically: true, encoding: .utf8)
        let restored = await GitService.pruneWorktrees(expected: missing.0, at: root.path)
        XCTAssertNotEqual(restored.status, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("child [1]/keep.txt")), "keep")
        let final = await GitService.worktrees(at: root.path)
        XCTAssertEqual(final.0.count, 2)
    }
    @MainActor
    func testMovePreservesIndexWorkingFilesIgnoredFilesAndBranch() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child [1]")
        _ = await CommandRunner.run(command: "printf staged > file.txt && git add file.txt && printf working > file.txt && printf '*.log' > .gitignore && printf keep > ignored.log && printf local > untracked.txt", cwd: child.path)
        let before = await GitService.worktrees(at: root.path)
        let snapshot = try XCTUnwrap(before.0.first { !$0.primary })
        let destination = root.appendingPathComponent("moved ' [2]")
        let moved = await GitService.moveWorktree(snapshot, destination: destination.path, at: root.path)
        XCTAssertEqual(moved.status, 0, moved.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("file.txt")), "working")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("ignored.log")), "keep")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("untracked.txt")), "local")
        let index = await CommandRunner.run(command: "git show :file.txt", cwd: destination.path)
        XCTAssertEqual(index.output, "staged")
        let after = await GitService.worktrees(at: destination.path)
        XCTAssertEqual(after.0.first { !$0.primary }?.path, destination.path)
        XCTAssertEqual(after.0.first { !$0.primary }?.branch, snapshot.branch)
        XCTAssertEqual(after.0.first { !$0.primary }?.hash, snapshot.hash)
    }

    @MainActor
    func testMoveRejectsPrimaryLockedStaleAndOccupiedOrNestedDestinations() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = await GitService.worktrees(at: root.path)
        let tree = try XCTUnwrap(before.0.first { !$0.primary })
        let destination = root.appendingPathComponent("destination")
        let primary = await GitService.moveWorktree(before.0[0], destination: destination.path, at: root.path)
        XCTAssertNotEqual(primary.status, 0)
        for invalid in ["relative", tree.path, root.appendingPathComponent(".git/inside").path, tree.path + "/inside", root.appendingPathComponent("missing/child").path] {
            let result = await GitService.moveWorktree(tree, destination: invalid, at: root.path)
            XCTAssertNotEqual(result.status, 0, invalid)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let existing = await GitService.moveWorktree(tree, destination: destination.path, at: root.path)
        XCTAssertNotEqual(existing.status, 0)
        try FileManager.default.removeItem(at: destination)
        _ = await GitService.setWorktreeLocked(tree, locked: true, reason: "keep", at: root.path)
        let stale = await GitService.moveWorktree(tree, destination: destination.path, at: root.path)
        XCTAssertNotEqual(stale.status, 0)
        let lockedList = await GitService.worktrees(at: root.path)
        let locked = try XCTUnwrap(lockedList.0.first { !$0.primary })
        let refused = await GitService.moveWorktree(locked, destination: destination.path, at: root.path)
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testMoveRejectsDestinationSymlinkAndExecutionInsideSource() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = await GitService.worktrees(at: root.path)
        let tree = try XCTUnwrap(before.0.first { !$0.primary })
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.appendingPathComponent("absent").path)
        let dangling = await GitService.moveWorktree(tree, destination: link.path, at: root.path)
        XCTAssertNotEqual(dangling.status, 0)
        let inside = await GitService.moveWorktree(tree, destination: root.appendingPathComponent("moved").path, at: tree.path)
        XCTAssertNotEqual(inside.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.path))
    }

    @MainActor
    func testMoveRefusesOpenNestedProjectBeforeChangingDisk() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = await GitService.worktrees(at: root.path)
        let tree = try XCTUnwrap(before.0.first { !$0.primary })
        let model = WorkbenchModel(restoringSession: false)
        let parent = Project(name: "parent", path: root.path)
        let nested = Project(name: "nested", path: tree.path + "/nested")
        model.projects = [parent, nested]; model.selectedProjectID = parent.id
        var result: CommandResult?
        model.moveWorktree(tree, destination: root.appendingPathComponent("moved").path) { result = $0 }
        XCTAssertNotEqual(try XCTUnwrap(result).status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.path))
        XCTAssertEqual(model.projects.count, 2)
    }

    @MainActor
    func testGitRefusesMoveWithSubmoduleAndPreservesFiles() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child [1]")
        let added = await CommandRunner.run(command: "git -c protocol.file.allow=always submodule add -q \(Shell.quote(root.path)) module", cwd: child.path)
        XCTAssertEqual(added.status, 0, added.output)
        let before = await GitService.worktrees(at: root.path)
        let tree = try XCTUnwrap(before.0.first { !$0.primary })
        let moved = await GitService.moveWorktree(tree, destination: root.appendingPathComponent("moved").path, at: root.path)
        XCTAssertNotEqual(moved.status, 0)
        XCTAssertEqual(try String(contentsOf: child.appendingPathComponent("module/file.txt")), "original")
    }

}
