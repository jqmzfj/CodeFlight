import XCTest
@testable import CodeFlightApp

final class GitMergeCommitActionTests: XCTestCase {
    @MainActor
    private func fixture() async throws -> (root: URL, base: String, merge: String) {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".git-merge-action-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf base > common.txt && git add . && git commit -qm base && git branch base && git switch -qc topic && printf topic > topic.txt && git add . && git commit -qm topic && git switch -q main && printf main > main.txt && git add . && git commit -qm main && git merge -q --no-ff topic -m 'Merge topic for action testing'", cwd: root.path)
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: root)
            throw NSError(domain: "MergeActionFixture", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.output])
        }
        let base = await GitService.commitHash("base", at: root.path)
        let merge = await GitService.commitHash("HEAD", at: root.path)
        return (root, try XCTUnwrap(base), try XCTUnwrap(merge))
    }

    @MainActor
    func testRevertMergeUsesSelectedParentAndPreservesUnrelatedWorkingChanges() async throws {
        for parent in [1, 2] {
            let fixture = try await fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let common = fixture.root.appendingPathComponent("common.txt")
            try Data("keep dirty".utf8).write(to: common)
            let result = await GitService.revert(fixture.merge, mainline: parent, at: fixture.root.path)
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("main.txt").path), parent == 1)
            XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("topic.txt").path), parent == 2)
            XCTAssertEqual(try String(contentsOf: common), "keep dirty")
            let state = await GitService.operationState(at: fixture.root.path)
            XCTAssertNil(state)
        }
    }

    @MainActor
    func testCherryPickMergeUsesOnlyChangesRelativeToSelectedParent() async throws {
        for parent in [1, 2] {
            let fixture = try await fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let checkout = await CommandRunner.run(command: "git switch -q --detach \(fixture.base)", cwd: fixture.root.path)
            XCTAssertEqual(checkout.status, 0, checkout.output)
            let result = await GitService.cherryPick(fixture.merge, mainline: parent, at: fixture.root.path)
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("main.txt").path), parent == 2)
            XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("topic.txt").path), parent == 1)
        }
    }

    @MainActor
    func testInvalidMainlineIsRejectedWithoutChangingHeadIndexOrWorktree() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selection = await GitService.commitTarget("HEAD", at: fixture.root.path)
        let target = try XCTUnwrap(selection)
        XCTAssertEqual(target.hash, fixture.merge)
        XCTAssertEqual(target.parents.count, 2)
        XCTAssertEqual(target.subject, "Merge topic for action testing")
        let before = await CommandRunner.run(command: "git ls-files --stage -z", cwd: fixture.root.path)
        for parent: Int? in [nil, 0, -1, 3] {
            let revert = await GitService.revert(fixture.merge, mainline: parent, at: fixture.root.path)
            let cherryPick = await GitService.cherryPick(fixture.merge, mainline: parent, at: fixture.root.path)
            XCTAssertNotEqual(revert.status, 0)
            XCTAssertNotEqual(cherryPick.status, 0)
        }
        let rootRevert = await GitService.revert(fixture.base, mainline: 1, at: fixture.root.path)
        let rootPick = await GitService.cherryPick(fixture.base, mainline: 1, at: fixture.root.path)
        XCTAssertNotEqual(rootRevert.status, 0)
        XCTAssertNotEqual(rootPick.status, 0)
        let head = await GitService.commitHash("HEAD", at: fixture.root.path)
        XCTAssertEqual(head, fixture.merge)
        let after = await CommandRunner.run(command: "git ls-files --stage -z", cwd: fixture.root.path)
        XCTAssertEqual(after.output, before.output)
        let status = await GitService.status(at: fixture.root.path)
        XCTAssertTrue(status.changes.isEmpty)
    }

    @MainActor
    func testMergeRevertConflictCanContinueAndRejectsNestedCommitActions() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("later edit".utf8).write(to: fixture.root.appendingPathComponent("topic.txt"))
        let commit = await CommandRunner.run(command: "git add topic.txt && git commit -qm followup", cwd: fixture.root.path)
        XCTAssertEqual(commit.status, 0, commit.output)
        let revert = await GitService.revert(fixture.merge, mainline: 1, at: fixture.root.path)
        XCTAssertNotEqual(revert.status, 0)
        let state = await GitService.operationState(at: fixture.root.path)
        XCTAssertEqual(state, .reverting)
        let status = await GitService.status(at: fixture.root.path)
        XCTAssertTrue(status.changes.contains(where: { $0.path == "topic.txt" && $0.isConflicted }))
        let nested = await GitService.cherryPick(fixture.base, at: fixture.root.path)
        XCTAssertNotEqual(nested.status, 0)
        XCTAssertTrue(nested.output.contains("Finish or abort"))
        let resolve = await CommandRunner.run(command: "git rm -q -- topic.txt", cwd: fixture.root.path)
        XCTAssertEqual(resolve.status, 0, resolve.output)
        let continued = await GitService.continueOperation(.reverting, at: fixture.root.path)
        XCTAssertEqual(continued.status, 0, continued.output)
        let completedState = await GitService.operationState(at: fixture.root.path)
        XCTAssertNil(completedState)
    }
}
