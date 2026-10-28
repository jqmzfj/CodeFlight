import XCTest
@testable import CodeFlightApp

final class GitInteractiveRebaseTests: XCTestCase {
    @MainActor
    private func fixture(dependent: Bool = false) async throws -> URL {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".git-interactive-rebase-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let setup = dependent
            ? "printf 'one\\n' > common.txt && git commit -qam A && printf 'two\\n' > common.txt && git commit -qam B && printf 'later\\n' > later.txt && git add . && git commit -qm C"
            : "for name in A B C D E; do printf '%s\\n' \"$name\" > \"$name.txt\" && git add . && git commit -qm \"$name\" || exit 1; done"
        let result = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && git config commit.gpgSign false && printf 'base\\n' > common.txt && git add . && git commit -qm base && git tag base && " + setup, cwd: root.path)
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: root)
            throw NSError(domain: "InteractiveFixture", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.output])
        }
        return root
    }

    @MainActor
    func testRewordFixupSquashAndDropProduceExpectedTreeAndMessages() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await GitService.interactiveRebaseSnapshot(base: "base", at: root.path)
        XCTAssertEqual(snapshot.commits.map(\.subject), ["A", "B", "C", "D", "E"])
        var steps = snapshot.steps
        steps[0].action = .reword
        steps[0].message = "new A 'quoted' $(touch injected)\n\nexec touch injected\n你好"
        steps[1].action = .fixup
        steps[2].action = .squash
        steps[3].action = .drop
        let result = await GitService.interactiveRebase(steps, snapshot: snapshot, at: root.path)
        XCTAssertEqual(result.status, 0, result.output)
        let log = await CommandRunner.run(command: "git log --reverse --format='%B%x00' base..HEAD --", cwd: root.path)
        let messages = log.output.split(separator: "\0").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages[0].contains(steps[0].message))
        XCTAssertTrue(messages[0].hasSuffix("C"))
        XCTAssertFalse(messages[0].contains("\nB\n"))
        XCTAssertEqual(messages[1], "E")
        for name in ["A", "B", "C", "E"] { XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(name + ".txt")), name + "\n") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("D.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path))
        let state = await GitService.operationState(at: root.path)
        XCTAssertNil(state)
    }

    @MainActor
    func testIndependentCommitsCanBeReorderedWithoutChangingOtherBranches() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await GitService.interactiveRebaseSnapshot(base: "base", at: root.path)
        _ = await CommandRunner.run(command: "git branch keep-original", cwd: root.path)
        let result = await GitService.interactiveRebase(Array(snapshot.steps.reversed()), snapshot: snapshot, at: root.path)
        XCTAssertEqual(result.status, 0, result.output)
        let log = await CommandRunner.run(command: "git log --reverse --format=%s base..HEAD --", cwd: root.path)
        XCTAssertEqual(log.output.trimmingCharacters(in: .newlines), "E\nD\nC\nB\nA")
        let original = await GitService.commitHash("keep-original", at: root.path)
        XCTAssertEqual(original, snapshot.head)
        let tree = await CommandRunner.run(command: "git diff --exit-code keep-original HEAD --", cwd: root.path)
        XCTAssertEqual(tree.status, 0, tree.output)
    }

    @MainActor
    func testConflictCanContinueAndLaterRewordSurvivesEditorCleanup() async throws {
        let root = try await fixture(dependent: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await GitService.interactiveRebaseSnapshot(base: "base", at: root.path)
        var steps = snapshot.steps
        steps[0].action = .drop
        steps[2].action = .reword
        steps[2].message = "later message\n\n中文 body"
        let result = await GitService.interactiveRebase(steps, snapshot: snapshot, at: root.path)
        XCTAssertNotEqual(result.status, 0)
        let state = await GitService.operationState(at: root.path)
        XCTAssertEqual(state, .rebasing)
        let nested = await GitService.interactiveRebase(steps, snapshot: snapshot, at: root.path)
        XCTAssertNotEqual(nested.status, 0)
        let conflict = await GitService.conflictSnapshot("common.txt", at: root.path)
        let saved = await GitService.saveConflict("common.txt", result: "two\n", snapshot: conflict, at: root.path)
        XCTAssertEqual(saved.status, 0, saved.output)
        let continued = await GitService.continueOperation(.rebasing, at: root.path)
        XCTAssertEqual(continued.status, 0, continued.output)
        let message = await GitService.amendSnapshot(at: root.path)
        XCTAssertEqual(message?.message, steps[2].message)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("later.txt")), "later\n")
        let finalState = await GitService.operationState(at: root.path)
        XCTAssertNil(finalState)
    }

    @MainActor
    func testConflictCanAbortRestoringOriginalBranchAndTree() async throws {
        let root = try await fixture(dependent: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await GitService.interactiveRebaseSnapshot(base: "base", at: root.path)
        var steps = snapshot.steps
        steps[0].action = .drop
        let result = await GitService.interactiveRebase(steps, snapshot: snapshot, at: root.path)
        XCTAssertNotEqual(result.status, 0)
        let aborted = await GitService.rebaseAbort(at: root.path)
        XCTAssertEqual(aborted.status, 0, aborted.output)
        let head = await GitService.commitHash("HEAD", at: root.path)
        XCTAssertEqual(head, snapshot.head)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("common.txt")), "two\n")
        let status = await GitService.status(at: root.path)
        XCTAssertEqual(status.branch, "main")
        XCTAssertTrue(status.changes.isEmpty)
    }

    @MainActor
    func testRejectsDirtyStaleAndSameHeadDifferentBranchWithoutChangingIndex() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await GitService.interactiveRebaseSnapshot(base: "base", at: root.path)
        _ = await CommandRunner.run(command: "printf dirty > common.txt && git add common.txt && printf worktree > common.txt", cwd: root.path)
        let index = await CommandRunner.run(command: "git ls-files --stage -z", cwd: root.path)
        let dirty = await GitService.interactiveRebase(snapshot.steps, snapshot: snapshot, at: root.path)
        XCTAssertNotEqual(dirty.status, 0)
        let afterIndex = await CommandRunner.run(command: "git ls-files --stage -z", cwd: root.path)
        XCTAssertEqual(index.output, afterIndex.output)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("common.txt")), "worktree")
        _ = await CommandRunner.run(command: "git restore --staged --worktree common.txt && git switch -qc other", cwd: root.path)
        let switched = await GitService.interactiveRebase(snapshot.steps, snapshot: snapshot, at: root.path)
        XCTAssertNotEqual(switched.status, 0)
        _ = await CommandRunner.run(command: "git switch -q main && printf new > new.txt && git add . && git commit -qm new", cwd: root.path)
        let before = await GitService.commitHash("HEAD", at: root.path)
        let stale = await GitService.interactiveRebase(snapshot.steps, snapshot: snapshot, at: root.path)
        XCTAssertNotEqual(stale.status, 0)
        let after = await GitService.commitHash("HEAD", at: root.path)
        XCTAssertEqual(before, after)
    }

    @MainActor
    func testRejectsInvalidPlansAndSupportsDroppingAllCommits() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await GitService.interactiveRebaseSnapshot(base: "base", at: root.path)
        var steps = snapshot.steps
        for action in [GitRebaseAction.squash, .fixup] {
            steps[0].action = action
            let result = await GitService.interactiveRebase(steps, snapshot: snapshot, at: root.path)
            XCTAssertNotEqual(result.status, 0)
        }
        steps = snapshot.steps
        steps[0].action = .reword
        for message in ["  \n", "bad\0message", String(repeating: "x", count: 65537)] {
            steps[0].message = message
            XCTAssertNotNil(GitService.rebasePlanError(steps, snapshot: snapshot))
        }
        XCTAssertNotNil(GitService.rebasePlanError(Array(snapshot.steps.dropFirst()), snapshot: snapshot))
        var duplicate = snapshot.steps
        duplicate[0] = duplicate[1]
        XCTAssertNotNil(GitService.rebasePlanError(duplicate, snapshot: snapshot))
        let head = await GitService.commitHash("HEAD", at: root.path)
        XCTAssertEqual(head, snapshot.head)
        steps = snapshot.steps
        for index in steps.indices { steps[index].action = .drop }
        let result = await GitService.interactiveRebase(steps, snapshot: snapshot, at: root.path)
        XCTAssertEqual(result.status, 0, result.output)
        let finalHead = await GitService.commitHash("HEAD", at: root.path)
        XCTAssertEqual(finalHead, snapshot.base)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("A.txt").path))
    }

    @MainActor
    func testSnapshotRejectsMergeRangeNonAncestorHeadAndDetachedBranch() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "git switch -qc side base && printf side > side.txt && git add . && git commit -qm side && git switch -q main", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        for ref in ["side", "HEAD", "--delete"] {
            do { _ = try await GitService.interactiveRebaseSnapshot(base: ref, at: root.path); XCTFail("Expected invalid base: \(ref)") } catch { }
        }
        _ = await CommandRunner.run(command: "git merge -q --no-ff side -m merge", cwd: root.path)
        do { _ = try await GitService.interactiveRebaseSnapshot(base: "base", at: root.path); XCTFail("Expected merge refusal") } catch { }
        _ = await CommandRunner.run(command: "git switch -q --detach HEAD", cwd: root.path)
        do { _ = try await GitService.interactiveRebaseSnapshot(base: "base", at: root.path); XCTFail("Expected detached refusal") } catch { }
    }
    @MainActor
    func testSnapshotBoundsHistoryAndPreservesInitiallyEmptyCommits() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "git tag near && for number in {1..200}; do git commit -q --allow-empty -m empty-$number || exit 1; done", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        let snapshot = try await GitService.interactiveRebaseSnapshot(base: "near", at: root.path)
        XCTAssertEqual(snapshot.commits.count, 200)
        XCTAssertEqual(snapshot.commits.first?.subject, "empty-1")
        XCTAssertEqual(snapshot.commits.last?.subject, "empty-200")
        _ = await CommandRunner.run(command: "git commit -q --allow-empty -m too-many", cwd: root.path)
        do { _ = try await GitService.interactiveRebaseSnapshot(base: "near", at: root.path); XCTFail("Expected range limit") }
        catch { XCTAssertTrue(error.localizedDescription.contains("200")) }
        let short = try await GitService.interactiveRebaseSnapshot(base: "HEAD~2", at: root.path)
        var steps = short.steps
        steps[0].action = .reword; steps[0].message = "empty rewritten"
        let result = await GitService.interactiveRebase(steps, snapshot: short, at: root.path)
        XCTAssertEqual(result.status, 0, result.output)
        let count = await CommandRunner.run(command: "git rev-list --count \(short.base)..HEAD", cwd: root.path)
        XCTAssertEqual(count.output.trimmingCharacters(in: .newlines), "2")
    }

}
