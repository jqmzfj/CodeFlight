import XCTest
@testable import CodeFlightApp

final class GitSkipOperationTests: XCTestCase {
    @MainActor
    private func fixture() async throws -> URL {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".git-skip-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf 'base\\n' > common.txt && git add . && git commit -qm base && git branch base", cwd: root.path)
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: root)
            throw NSError(domain: "SkipFixture", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.output])
        }
        return root
    }

    @MainActor
    func testEmptyCherryPickCanBeSkippedAndRemainingCommitApplied() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "git switch -qc topic && printf 'first\\n' > first.txt && git add . && git commit -qm first && git tag first && printf 'second\\n' > second.txt && git add . && git commit -qm second && git tag second && git switch -q main && git cherry-pick first && git cherry-pick first second", cwd: root.path)
        XCTAssertNotEqual(setup.status, 0)
        let state = await GitService.operationState(at: root.path)
        XCTAssertEqual(state, .cherryPicking)
        let skipped = await GitService.skipOperation(.cherryPicking, at: root.path)
        XCTAssertEqual(skipped.status, 0, skipped.output)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("second.txt")), "second\n")
        let finalState = await GitService.operationState(at: root.path)
        XCTAssertNil(finalState)
        let status = await GitService.status(at: root.path)
        XCTAssertNil(status.error)
        XCTAssertTrue(status.changes.isEmpty)
    }

    @MainActor
    func testRebaseSkipDiscardsConflictButKeepsLaterCommit() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "git switch -qc topic && printf 'topic\\n' > common.txt && git commit -qam topic && printf 'later\\n' > later.txt && git add . && git commit -qm later && git switch -q main && printf 'main\\n' > common.txt && git commit -qam main && git switch -q topic && git rebase main", cwd: root.path)
        XCTAssertNotEqual(setup.status, 0)
        let state = await GitService.operationState(at: root.path)
        XCTAssertEqual(state, .rebasing)
        let skipped = await GitService.skipOperation(.rebasing, at: root.path)
        XCTAssertEqual(skipped.status, 0, skipped.output)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("common.txt")), "main\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("later.txt")), "later\n")
        let finalState = await GitService.operationState(at: root.path)
        XCTAssertNil(finalState)
    }

    @MainActor
    func testRevertSkipPreservesHeadAndUnrelatedDirtyFile() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "printf 'change\\n' > common.txt && git commit -qam change && git tag change && printf 'later\\n' > common.txt && printf 'keep\\n' > unrelated.txt && git add . && git commit -qm later && printf 'dirty\\n' > unrelated.txt && git revert --no-edit change", cwd: root.path)
        XCTAssertNotEqual(setup.status, 0)
        let before = await GitService.commitHash("HEAD", at: root.path)
        let state = await GitService.operationState(at: root.path)
        XCTAssertEqual(state, .reverting)
        let skipped = await GitService.skipOperation(.reverting, at: root.path)
        XCTAssertEqual(skipped.status, 0, skipped.output)
        let after = await GitService.commitHash("HEAD", at: root.path)
        XCTAssertEqual(after, before)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("common.txt")), "later\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("unrelated.txt")), "dirty\n")
        let finalState = await GitService.operationState(at: root.path)
        XCTAssertNil(finalState)
    }

    @MainActor
    func testSkipRejectsWrongStateAndMergeWithoutChangingWorktree() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let noOperation = await GitService.skipOperation(.cherryPicking, at: root.path)
        XCTAssertNotEqual(noOperation.status, 0)
        let setup = await CommandRunner.run(command: "git switch -qc topic && printf 'topic\\n' > common.txt && git commit -qam topic && git switch -q main && printf 'main\\n' > common.txt && git commit -qam main && git merge topic", cwd: root.path)
        XCTAssertNotEqual(setup.status, 0)
        let before = try Data(contentsOf: root.appendingPathComponent("common.txt"))
        let index = await CommandRunner.run(command: "git ls-files -u -z", cwd: root.path)
        for state in [GitOperationState.merging, .cherryPicking, .reverting, .rebasing] {
            let result = await GitService.skipOperation(state, at: root.path)
            XCTAssertNotEqual(result.status, 0)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("common.txt")), before)
        let afterIndex = await CommandRunner.run(command: "git ls-files -u -z", cwd: root.path)
        XCTAssertEqual(index.output, afterIndex.output)
        let state = await GitService.operationState(at: root.path)
        XCTAssertEqual(state, .merging)
        XCTAssertNil(GitOperationState.merging.skipOperation)
    }
}
