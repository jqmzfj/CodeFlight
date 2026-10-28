import XCTest
import Darwin
import AppKit
@testable import CodeFlightApp

final class CodeFlightAppTests: XCTestCase {
    private var workspaceRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    @MainActor
    func testStashApplyRestoresDistinctIndexAndWorktreeWhenRequested() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-stash-index-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf original > file.txt && git add . && git commit -qm original && printf staged > file.txt && git add file.txt && printf unstaged > file.txt && printf untracked > new.txt", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        let saved = await GitService.saveStash(message: "restore index", includeUntracked: true, keepIndex: false, at: root.path)
        XCTAssertEqual(saved.status, 0, saved.output)
        let values = await GitService.stashes(at: root.path)
        let stash = try XCTUnwrap(values.first)
        let applied = await GitService.stashAction(.apply, stash: stash, restoreIndex: true, at: root.path)
        XCTAssertEqual(applied.status, 0, applied.output)
        let index = await CommandRunner.run(command: "git show :file.txt", cwd: root.path)
        XCTAssertEqual(index.output, "staged")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "unstaged")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new.txt")), "untracked")
        let retained = await GitService.stashes(at: root.path)
        XCTAssertEqual(retained.map(\.hash), [stash.hash])
    }

    @MainActor
    func testWorktreeCreateListAndRemovePreservesBranchAndPrimaryChanges() async throws {
        let root = try await worktreeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = root.appendingPathComponent("linked [1]\nspace")
        try Data("dirty primary".utf8).write(to: root.appendingPathComponent("file.txt"))
        let created = await GitService.addWorktree(destination: location.path, mode: .newBranch, branch: "feature/one", target: "HEAD", at: root.path)
        XCTAssertEqual(created.status, 0, created.output)
        XCTAssertEqual(try String(contentsOf: location.appendingPathComponent("file.txt")), "original")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "dirty primary")
        let listed = await GitService.worktrees(at: location.path)
        XCTAssertNil(listed.1)
        XCTAssertEqual(listed.0.count, 2)
        XCTAssertTrue(listed.0[0].primary)
        let linked = try XCTUnwrap(listed.0.first(where: { !$0.primary }))
        XCTAssertEqual(linked.path, location.path)
        XCTAssertEqual(linked.branch, "refs/heads/feature/one")
        let primaryRemoval = await GitService.removeWorktree(listed.0[0], at: root.path)
        XCTAssertNotEqual(primaryRemoval.status, 0)
        let removed = await GitService.removeWorktree(linked, at: root.path)
        XCTAssertEqual(removed.status, 0, removed.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
        let branch = await GitService.commitHash("refs/heads/feature/one", at: root.path)
        XCTAssertEqual(branch, linked.hash)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "dirty primary")
    }

    @MainActor
    func testWorktreeRemovalRejectsDirtyUntrackedLockedAndStaleState() async throws {
        let root = try await worktreeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = root.appendingPathComponent("linked")
        let created = await GitService.addWorktree(destination: location.path, mode: .newBranch, branch: "feature", target: "HEAD", at: root.path)
        XCTAssertEqual(created.status, 0, created.output)
        let initial = await GitService.worktrees(at: root.path)
        let snapshot = try XCTUnwrap(initial.0.first(where: { !$0.primary }))
        try Data("new".utf8).write(to: location.appendingPathComponent("untracked.txt"))
        let untracked = await GitService.removeWorktree(snapshot, at: root.path)
        XCTAssertNotEqual(untracked.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.appendingPathComponent("untracked.txt").path))
        try FileManager.default.removeItem(at: location.appendingPathComponent("untracked.txt"))
        try Data("dirty".utf8).write(to: location.appendingPathComponent("file.txt"))
        let dirty = await GitService.removeWorktree(snapshot, at: root.path)
        XCTAssertNotEqual(dirty.status, 0)
        try Data("original".utf8).write(to: location.appendingPathComponent("file.txt"))
        _ = await CommandRunner.run(command: "git worktree lock --reason 'keep this checkout' -- \(Shell.quote(location.path))", cwd: root.path)
        let lockedList = await GitService.worktrees(at: root.path)
        XCTAssertEqual(lockedList.0.first(where: { !$0.primary })?.locked, "keep this checkout")
        let locked = await GitService.removeWorktree(snapshot, at: root.path)
        XCTAssertNotEqual(locked.status, 0)
        _ = await CommandRunner.run(command: "git worktree unlock -- \(Shell.quote(location.path))", cwd: root.path)
        let commit = await CommandRunner.run(command: "git commit --allow-empty -qm next", cwd: location.path)
        XCTAssertEqual(commit.status, 0, commit.output)
        let stale = await GitService.removeWorktree(snapshot, at: root.path)
        XCTAssertNotEqual(stale.status, 0)
        let fresh = await GitService.worktrees(at: root.path)
        let latest = try XCTUnwrap(fresh.0.first(where: { !$0.primary }))
        let removed = await GitService.removeWorktree(latest, at: root.path)
        XCTAssertEqual(removed.status, 0, removed.output)
    }

    @MainActor
    func testWorktreeExistingDetachedAndNonemptyDestination() async throws {
        let root = try await worktreeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let location = root.appendingPathComponent("existing")
        let inUse = await GitService.addWorktree(destination: location.path, mode: .existingBranch, branch: "main", target: "HEAD", at: root.path)
        XCTAssertNotEqual(inUse.status, 0)
        _ = await GitService.createBranch("existing", checkout: false, at: root.path)
        let existing = await GitService.addWorktree(destination: location.path, mode: .existingBranch, branch: "existing", target: "HEAD", at: root.path)
        XCTAssertEqual(existing.status, 0, existing.output)
        let branch = await GitService.syncInfo(at: location.path)
        XCTAssertEqual(branch.branch, "existing")
        let detachedLocation = root.appendingPathComponent("detached")
        let detached = await GitService.addWorktree(destination: detachedLocation.path, mode: .detached, branch: "", target: "HEAD", at: root.path)
        XCTAssertEqual(detached.status, 0, detached.output)
        let trees = await GitService.worktrees(at: root.path)
        XCTAssertTrue(trees.0.contains(where: { $0.path == detachedLocation.path && $0.branch.isEmpty && !$0.primary }))
        let occupied = root.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: occupied.appendingPathComponent("keep.txt"))
        let refused = await GitService.addWorktree(destination: occupied.path, mode: .detached, branch: "", target: "HEAD", at: root.path)
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertEqual(try String(contentsOf: occupied.appendingPathComponent("keep.txt")), "keep")
        let relative = await GitService.addWorktree(destination: "relative", mode: .detached, branch: "", target: "HEAD", at: root.path)
        XCTAssertNotEqual(relative.status, 0)
    }

    @MainActor
    private func worktreeFixture() async throws -> URL {
        let root = workspaceRoot.appendingPathComponent(".git-worktree-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf original > file.txt && git add file.txt && git commit -qm original", cwd: root.path)
        guard setup.status == 0 else { try? FileManager.default.removeItem(at: root); throw NSError(domain: "WorktreeFixture", code: Int(setup.status), userInfo: [NSLocalizedDescriptionKey: setup.output]) }
        return root
    }

    func testRemotePushDestinationLabelOmitsEmbeddedCredentials() {
        let target = GitRemoteBranchSnapshot(remote: "origin", branch: "main", hash: String(repeating: "a", count: 40), pushURL: "https://test-user:test-secret@example.com/team/repo.git?access_token=test-token#private")
        XCTAssertEqual(target.displayPushURL, "https://example.com/team/repo.git")
    }

    @MainActor
    func testForcePushAmendedHistorySetsUpstreamAndPreservesWorktree() async throws {
        let root = try await forcePushFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ordinary = await GitService.push(remote: "origin", branch: "main", setUpstream: false, at: root.path)
        XCTAssertNotEqual(ordinary.status, 0)
        let value = await GitService.forcePushSnapshot(remote: "origin", branch: "main", at: root.path)
        let snapshot = try XCTUnwrap(value)
        XCTAssertNotEqual(snapshot.sourceHash, snapshot.destination.hash)
        try Data("dirty".utf8).write(to: root.appendingPathComponent("file.txt"))
        let result = await GitService.forcePush(snapshot, setUpstream: true, at: root.path)
        XCTAssertEqual(result.status, 0, result.output)
        let remote = await CommandRunner.run(command: "git --git-dir=remote.git rev-parse refs/heads/main", cwd: root.path)
        XCTAssertEqual(remote.output.trimmingCharacters(in: .whitespacesAndNewlines), snapshot.sourceHash)
        let tracking = await GitService.commitHash("refs/remotes/origin/main", at: root.path)
        XCTAssertEqual(tracking, snapshot.sourceHash)
        let info = await GitService.syncInfo(at: root.path)
        XCTAssertEqual(info.upstream, "origin/main")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "dirty")
        let index = await CommandRunner.run(command: "git diff --cached --name-only", cwd: root.path)
        XCTAssertTrue(index.output.isEmpty)
    }

    @MainActor
    func testForcePushRefusesUnseenRemoteCommit() async throws {
        let root = try await forcePushFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = await GitService.forcePushSnapshot(remote: "origin", branch: "main", at: root.path)
        let snapshot = try XCTUnwrap(value)
        let move = await CommandRunner.run(command: "git commit --allow-empty -qm collaborator && git push -q origin HEAD:refs/heads/transfer && git --git-dir=remote.git update-ref refs/heads/main refs/heads/transfer && git reset --soft \(snapshot.sourceHash)", cwd: root.path)
        XCTAssertEqual(move.status, 0, move.output)
        let refused = await GitService.forcePush(snapshot, setUpstream: false, at: root.path)
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertTrue(refused.output.contains("Remote has new commits"), refused.output)
        let tracking = await GitService.commitHash("refs/remotes/origin/main", at: root.path)
        XCTAssertEqual(tracking, snapshot.destination.hash)
    }

    @MainActor
    func testForcePushRejectsStaleLocalCommitAndChangedDestination() async throws {
        let root = try await forcePushFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = await GitService.forcePushSnapshot(remote: "origin", branch: "main", at: root.path)
        let snapshot = try XCTUnwrap(value)
        let amend = await CommandRunner.run(command: "git commit --amend -qm newer", cwd: root.path)
        XCTAssertEqual(amend.status, 0, amend.output)
        let stale = await GitService.forcePush(snapshot, setUpstream: false, at: root.path)
        XCTAssertNotEqual(stale.status, 0)
        let freshValue = await GitService.forcePushSnapshot(remote: "origin", branch: "main", at: root.path)
        let fresh = try XCTUnwrap(freshValue)
        _ = await CommandRunner.run(command: "git remote set-url --push origin ./unavailable.git", cwd: root.path)
        let redirected = await GitService.forcePush(fresh, setUpstream: false, at: root.path)
        XCTAssertNotEqual(redirected.status, 0)
        let original = await CommandRunner.run(command: "git --git-dir=remote.git rev-parse refs/heads/main", cwd: root.path)
        XCTAssertEqual(original.output.trimmingCharacters(in: .whitespacesAndNewlines), snapshot.destination.hash)
        let unknown = await GitService.forcePushSnapshot(remote: "origin", branch: "new-branch", at: root.path)
        XCTAssertNil(unknown)
    }

    @MainActor
    private func forcePushFixture() async throws -> URL {
        let root = workspaceRoot.appendingPathComponent(".git-force-push-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf original > file.txt && git add . && git commit -qm original && git init -q --bare remote.git && git remote add origin ./remote.git && git push -q origin main && git commit --amend -qm amended", cwd: root.path)
        guard setup.status == 0 else { try? FileManager.default.removeItem(at: root); throw NSError(domain: "ForcePushFixture", code: Int(setup.status), userInfo: [NSLocalizedDescriptionKey: setup.output]) }
        return root
    }

    @MainActor
    func testBranchListsExcludeDetachedAndSymbolicRemoteHEAD() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-branch-list-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf original > file.txt && git add . && git commit -qm original && git branch topic && git update-ref refs/remotes/origin/main HEAD && git update-ref refs/remotes/origin/feature/nested HEAD && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main && git switch -q --detach HEAD", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        let local = await GitService.branches(at: root.path)
        let remote = await GitService.remoteBranches(at: root.path)
        XCTAssertEqual(local, ["main", "topic"])
        XCTAssertEqual(remote, ["origin/feature/nested", "origin/main"])
    }

    @MainActor
    func testRemoteBranchDeletionLeaseAndLocalBranchPreservation() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-remote-delete-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf original > file.txt && git add . && git commit -qm original && git branch topic && git init -q --bare remote.git && git remote add origin ./remote.git && git push -q origin main topic && printf updated > file.txt && git add file.txt && git commit -qm updated", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        let value = await GitService.remoteBranchSnapshot("origin/topic", at: root.path)
        let snapshot = try XCTUnwrap(value)
        let updatedValue = await GitService.commitHash("HEAD", at: root.path)
        let updated = try XCTUnwrap(updatedValue)
        // Transfer the commit, then advance only the server ref, leaving the tracking ref stale.
        let serverChange = await CommandRunner.run(command: "git push -q origin main && git --git-dir=remote.git update-ref refs/heads/topic \(updated)", cwd: root.path)
        XCTAssertEqual(serverChange.status, 0, serverChange.output)
        let refused = await GitService.deleteRemoteBranch(snapshot, at: root.path)
        XCTAssertNotEqual(refused.status, 0, refused.output)
        XCTAssertTrue(refused.output.contains("Remote branch changed"), refused.output)
        let retained = await CommandRunner.run(command: "git --git-dir=remote.git rev-parse refs/heads/topic", cwd: root.path)
        XCTAssertEqual(retained.output.trimmingCharacters(in: .whitespacesAndNewlines), updated)
        let fetched = await GitService.fetch(remote: "origin", at: root.path)
        XCTAssertEqual(fetched.status, 0, fetched.output)
        let freshValue = await GitService.remoteBranchSnapshot("origin/topic", at: root.path)
        let fresh = try XCTUnwrap(freshValue)
        try Data("dirty".utf8).write(to: root.appendingPathComponent("file.txt"))
        let deleted = await GitService.deleteRemoteBranch(fresh, at: root.path)
        XCTAssertEqual(deleted.status, 0, deleted.output)
        let missing = await CommandRunner.run(command: "git --git-dir=remote.git show-ref --verify --quiet refs/heads/topic", cwd: root.path)
        XCTAssertNotEqual(missing.status, 0)
        let tracking = await GitService.commitHash("refs/remotes/origin/topic", at: root.path)
        XCTAssertNil(tracking)
        let localTopic = await GitService.commitHash("refs/heads/topic", at: root.path)
        XCTAssertEqual(localTopic, snapshot.hash)
        let remoteMain = await CommandRunner.run(command: "git --git-dir=remote.git rev-parse refs/heads/main", cwd: root.path)
        XCTAssertEqual(remoteMain.output.trimmingCharacters(in: .whitespacesAndNewlines), updated)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "dirty")
    }

    @MainActor
    func testRemoteBranchDeletionRejectsChangedDestinationAndMultiplePushURLs() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-remote-delete-config-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf original > file.txt && git add . && git commit -qm original && git init -q --bare remote.git && git init -q --bare other.git && git remote add origin ./remote.git && git push -q origin main", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        let value = await GitService.remoteBranchSnapshot("origin/main", at: root.path)
        let snapshot = try XCTUnwrap(value)
        _ = await CommandRunner.run(command: "git remote set-url --push origin ./other.git", cwd: root.path)
        let changed = await GitService.deleteRemoteBranch(snapshot, at: root.path)
        XCTAssertNotEqual(changed.status, 0)
        let retained = await CommandRunner.run(command: "git --git-dir=remote.git show-ref --verify --quiet refs/heads/main", cwd: root.path)
        XCTAssertEqual(retained.status, 0)
        _ = await CommandRunner.run(command: "git remote set-url --add --push origin ./remote.git", cwd: root.path)
        let multiple = await GitService.remoteBranchSnapshot("origin/main", at: root.path)
        XCTAssertNil(multiple)
        let headAlias = await GitService.remoteBranchSnapshot("origin/HEAD", at: root.path)
        XCTAssertNil(headAlias)
        let unknown = await GitService.remoteBranchSnapshot("unknown/main", at: root.path)
        XCTAssertNil(unknown)
    }

    @MainActor
    func testBranchComparisonScopesRenamesAndImmutableSnapshot() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-compare-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf 'original\\n' > 'old[1].txt' && git add . && git commit -qm base && git branch feature && printf current > current.txt && git add . && git commit -qm current && git checkout -q feature && git mv 'old[1].txt' 'new[1].txt' && printf feature > feature.txt && git add . && git commit -qm feature && git checkout -q main", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        try Data("dirty".utf8).write(to: root.appendingPathComponent("current.txt"))
        let endpoints = await GitService.compareBranches(target: "refs/heads/feature", fromMergeBase: false, at: root.path)
        let snapshot = try XCTUnwrap(endpoints.0, endpoints.1 ?? "")
        XCTAssertEqual(snapshot.currentOnly, 1)
        XCTAssertEqual(snapshot.targetOnly, 1)
        XCTAssertEqual(Set(snapshot.files.map(\.path)), ["current.txt", "feature.txt", "new[1].txt"])
        let rename = try XCTUnwrap(snapshot.files.first(where: { $0.path == "new[1].txt" }))
        XCTAssertEqual(rename.oldPath, "old[1].txt")
        let renameDiff = await GitService.comparisonDiff(snapshot, file: rename, at: root.path)
        XCTAssertTrue(renameDiff.contains("rename from old[1].txt"), renameDiff)
        XCTAssertTrue(renameDiff.contains("rename to new[1].txt"), renameDiff)
        let introduced = await GitService.compareBranches(target: "feature", fromMergeBase: true, at: root.path)
        let introducedSnapshot = try XCTUnwrap(introduced.0, introduced.1 ?? "")
        XCTAssertEqual(Set(introducedSnapshot.files.map(\.path)), ["feature.txt", "new[1].txt"])
        XCTAssertNotEqual(introducedSnapshot.base, snapshot.current)
        let moved = await CommandRunner.run(command: "git branch -f feature main", cwd: root.path)
        XCTAssertEqual(moved.status, 0, moved.output)
        let feature = try XCTUnwrap(snapshot.files.first(where: { $0.path == "feature.txt" }))
        let oldDiff = await GitService.comparisonDiff(snapshot, file: feature, at: root.path)
        XCTAssertTrue(oldDiff.contains("+feature"), oldDiff)
        let fresh = await GitService.compareBranches(target: "feature", fromMergeBase: false, at: root.path)
        XCTAssertEqual(fresh.0?.files.count, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("current.txt")), "dirty")
        let index = await CommandRunner.run(command: "git diff --cached --name-only", cwd: root.path)
        XCTAssertTrue(index.output.isEmpty)
    }

    @MainActor
    func testBranchComparisonUnrelatedHistoryAndInvalidRef() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-compare-unrelated-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf first > first.txt && git add . && git commit -qm first && git checkout -q --orphan other && git rm -q -f first.txt && printf second > second.txt && git add . && git commit -qm second && git checkout -q main", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        let common = await GitService.compareBranches(target: "other", fromMergeBase: true, at: root.path)
        XCTAssertNil(common.0)
        XCTAssertNotNil(common.1)
        let endpoints = await GitService.compareBranches(target: "other", fromMergeBase: false, at: root.path)
        XCTAssertEqual(endpoints.0?.files.count, 2)
        XCTAssertEqual(endpoints.0?.currentOnly, 1)
        XCTAssertEqual(endpoints.0?.targetOnly, 1)
        let invalid = await GitService.compareBranches(target: "--help", fromMergeBase: false, at: root.path)
        XCTAssertNil(invalid.0)
        XCTAssertNotNil(invalid.1)
    }

    @MainActor
    func testAmendMessageOnlyPreservesIndexThenIncludesOnlyStagedContent() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-amend-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "git init -q && git config user.name Test && git config user.email test@example.com && printf original > file.txt && git add . && git commit -qm initial", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        let originalValue = await GitService.amendSnapshot(at: root.path)
        let original = try XCTUnwrap(originalValue)
        try Data("staged".utf8).write(to: root.appendingPathComponent("file.txt"))
        _ = await GitService.fileAction(.stage, path: "file.txt", at: root.path)
        try Data("unstaged".utf8).write(to: root.appendingPathComponent("file.txt"))
        let messageOnly = await GitService.amend(message: "rename 'message'\n\nbody", expectedHEAD: original.hash, includeStaged: false, at: root.path)
        XCTAssertEqual(messageOnly.status, 0, messageOnly.output)
        let amendedValue = await GitService.amendSnapshot(at: root.path)
        let amended = try XCTUnwrap(amendedValue)
        XCTAssertNotEqual(amended.hash, original.hash)
        XCTAssertEqual(amended.message, "rename 'message'\n\nbody")
        let headContent = await CommandRunner.run(command: "git show HEAD:file.txt", cwd: root.path)
        let indexContent = await CommandRunner.run(command: "git show :file.txt", cwd: root.path)
        XCTAssertEqual(headContent.output, "original")
        XCTAssertEqual(indexContent.output, "staged")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "unstaged")
        let stale = await GitService.amend(message: "stale", expectedHEAD: original.hash, includeStaged: true, at: root.path)
        XCTAssertNotEqual(stale.status, 0)
        let included = await GitService.amend(message: "include staged", expectedHEAD: amended.hash, includeStaged: true, at: root.path)
        XCTAssertEqual(included.status, 0, included.output)
        let finalContent = await CommandRunner.run(command: "git show HEAD:file.txt", cwd: root.path)
        let count = await CommandRunner.run(command: "git rev-list --count HEAD", cwd: root.path)
        XCTAssertEqual(finalContent.output, "staged")
        XCTAssertEqual(count.output.trimmingCharacters(in: .whitespacesAndNewlines), "1")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "unstaged")
    }

    @MainActor
    func testAmendRejectsUnbornAndUnfinishedMerge() async throws {
        let root = try await conflictFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let value = await GitService.amendSnapshot(at: root.path)
        let snapshot = try XCTUnwrap(value)
        let result = await GitService.amend(message: "invalid", expectedHEAD: snapshot.hash, includeStaged: true, at: root.path)
        XCTAssertNotEqual(result.status, 0)
        let after = await GitService.amendSnapshot(at: root.path)
        XCTAssertEqual(after?.hash, snapshot.hash)
        let unborn = workspaceRoot.appendingPathComponent(".git-amend-unborn-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: unborn, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unborn) }
        _ = await CommandRunner.run(command: "git init -q", cwd: unborn.path)
        let empty = await GitService.amendSnapshot(at: unborn.path)
        XCTAssertNil(empty)
    }

    @MainActor
    func testMergeHistoryFilesMatchFirstParentDiff() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-merge-history-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf base > base.txt && git add . && git commit -qm base && git branch incoming && printf main > main.txt && git add . && git commit -qm 'main change' && git checkout -q incoming && printf incoming > incoming.txt && git add . && git commit -qm 'incoming change' && git checkout -q main && git merge --no-edit incoming", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        let files = await GitService.commitFiles("HEAD", at: root.path)
        XCTAssertEqual(files, ["incoming.txt"])
        for file in files {
            let diff = await GitService.commitDiff("HEAD", file: file, at: root.path)
            XCTAssertTrue(diff.contains("+incoming"), diff)
        }
        let ownBranchFile = await GitService.commitDiff("HEAD", file: "main.txt", at: root.path)
        XCTAssertTrue(ownBranchFile.isEmpty)
    }

    @MainActor
    func testFileHistoryFollowsRenamesAcrossPagesAndUsesLiteralPaths() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-file-history-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git init -q && git config user.name Test && git config user.email test@example.com", cwd: root.path)
        let original = "old [name]\nfile.txt", middle = "middle.txt", current = "new [name].txt"
        try Data("original\n".utf8).write(to: root.appendingPathComponent(original))
        _ = await CommandRunner.run(command: "git add . && git commit -qm first", cwd: root.path)
        _ = await CommandRunner.run(command: "git mv -- \(Shell.quote(original)) \(Shell.quote(middle)) && git commit -qm rename1", cwd: root.path)
        _ = await CommandRunner.run(command: "git mv -- \(Shell.quote(middle)) \(Shell.quote(current)) && git commit -qm rename2", cwd: root.path)
        try Data("original\nchanged\n".utf8).write(to: root.appendingPathComponent(current))
        _ = await CommandRunner.run(command: "git add . && git commit -qm changed", cwd: root.path)
        try Data("other".utf8).write(to: root.appendingPathComponent("new n.txt"))
        _ = await CommandRunner.run(command: "git add . && git commit -qm unrelated", cwd: root.path)
        var entries: [GitFileHistoryEntry] = []
        for pageIndex in 0..<4 {
            let page = await GitService.fileHistory(current, at: root.path, skip: pageIndex, limit: 1)
            XCTAssertNil(page.error)
            XCTAssertEqual(page.entries.count, 1)
            XCTAssertEqual(page.hasMore, pageIndex < 3)
            entries.append(contentsOf: page.entries)
        }
        XCTAssertEqual(entries.map { $0.commit.subject }, ["changed", "rename2", "rename1", "first"])
        XCTAssertEqual(entries.map(\.path), [current, current, middle, original])
        let oldest = try XCTUnwrap(entries.last)
        let diff = await GitService.commitDiff(oldest.id, file: oldest.path, at: root.path)
        XCTAssertTrue(diff.contains("+original"), diff)
        let absent = await GitService.fileHistory("never-tracked.txt", at: root.path)
        XCTAssertTrue(absent.entries.isEmpty)
        XCTAssertFalse(absent.hasMore)
        XCTAssertNil(absent.error)
        _ = await CommandRunner.run(command: "git checkout -q --orphan empty", cwd: root.path)
        let unborn = await GitService.fileHistory(current, at: root.path)
        XCTAssertTrue(unborn.entries.isEmpty)
        XCTAssertFalse(unborn.hasMore)
        XCTAssertNil(unborn.error)
    }

    @MainActor
    func testFileHistoryRequestValidatesProjectAndClearsOnProjectChange() {
        let model = WorkbenchModel(restoringSession: false)
        let project = Project(name: "fixture", path: workspaceRoot.path)
        model.projects = [project]; model.selectedProjectID = project.id; model.isGitRepository = true
        let request = model.gitFileHistoryRequest
        model.showFileHistory("/outside/file.txt")
        XCTAssertNil(model.gitFileHistoryPath)
        XCTAssertEqual(model.gitFileHistoryRequest, request)
        model.showFileHistory(workspaceRoot.appendingPathComponent("file.txt").path)
        XCTAssertEqual(model.gitFileHistoryPath, "file.txt")
        XCTAssertNotEqual(model.gitFileHistoryRequest, request)
        model.closeProject(project.id)
        XCTAssertNil(model.gitFileHistoryPath)
    }

    @MainActor
    private func tagFixture() async throws -> URL {
        let root = workspaceRoot.appendingPathComponent(".git-tag-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf original > file.txt && git add . && git commit -qm first && printf changed > file.txt && git add . && git commit -qm second", cwd: root.path)
        guard setup.status == 0 else { try? FileManager.default.removeItem(at: root); throw NSError(domain: "TagFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: setup.output]) }
        return root
    }

    @MainActor
    func testTagsCreateAtChosenCommitAndPreserveWorktree() async throws {
        let root = try await tagFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("working".utf8).write(to: root.appendingPathComponent("file.txt"))
        let original = await GitService.commitHash("HEAD^", at: root.path)
        let simple = await GitService.createTag("release/1.0", target: "HEAD^", at: root.path)
        XCTAssertEqual(simple.status, 0, simple.output)
        let simpleValue = await GitService.tagDetails("release/1.0", at: root.path)
        let lightweight = try XCTUnwrap(simpleValue)
        XCTAssertFalse(lightweight.annotated)
        XCTAssertEqual(lightweight.commitID, original)
        let note = "release 'notes'\n\nwith body"
        let annotated = await GitService.createTag("release/2.0", target: "HEAD", message: note, at: root.path)
        XCTAssertEqual(annotated.status, 0, annotated.output)
        let detailedValue = await GitService.tagDetails("release/2.0", at: root.path)
        let detailed = try XCTUnwrap(detailedValue)
        XCTAssertTrue(detailed.annotated)
        XCTAssertNotEqual(detailed.objectID, detailed.commitID)
        XCTAssertEqual(detailed.message, note)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "working")
        let duplicate = await GitService.createTag("release/1.0", at: root.path)
        XCTAssertNotEqual(duplicate.status, 0)
        let invalid = await GitService.createTag("-d", at: root.path)
        XCTAssertNotEqual(invalid.status, 0)
        let missingTarget = await GitService.createTag("valid", target: "missing", at: root.path)
        XCTAssertNotEqual(missingTarget.status, 0)
    }

    @MainActor
    func testTagDeletionRejectsMovedTagAndCheckoutDoesNotLoseChanges() async throws {
        let root = try await tagFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await GitService.createTag("version", target: "HEAD^", at: root.path)
        let oldValue = await GitService.tagDetails("version", at: root.path)
        let old = try XCTUnwrap(oldValue)
        _ = await CommandRunner.run(command: "git tag -f version HEAD", cwd: root.path)
        let staleDelete = await GitService.deleteTag(old, at: root.path)
        XCTAssertNotEqual(staleDelete.status, 0)
        let staleCheckout = await GitService.checkoutTag(old, at: root.path)
        XCTAssertNotEqual(staleCheckout.status, 0)
        let value = await GitService.tagDetails("version", at: root.path)
        let current = try XCTUnwrap(value)
        XCTAssertNotEqual(current.objectID, old.objectID)
        let deleted = await GitService.deleteTag(current, at: root.path)
        XCTAssertEqual(deleted.status, 0, deleted.output)
        let absent = await GitService.tagDetails("version", at: root.path)
        XCTAssertNil(absent)
        _ = await GitService.createTag("older", target: "HEAD^", at: root.path)
        let olderValue = await GitService.tagDetails("older", at: root.path)
        let older = try XCTUnwrap(olderValue)
        try Data("local changes".utf8).write(to: root.appendingPathComponent("file.txt"))
        let refused = await GitService.checkoutTag(older, at: root.path)
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "local changes")
        _ = await CommandRunner.run(command: "git restore file.txt", cwd: root.path)
        let checkout = await GitService.checkoutTag(older, at: root.path)
        XCTAssertEqual(checkout.status, 0, checkout.output)
        let info = await GitService.syncInfo(at: root.path)
        XCTAssertTrue(info.branch.isEmpty)
        let head = await GitService.commitHash("HEAD", at: root.path)
        XCTAssertEqual(head, older.commitID)
    }

    @MainActor
    func testPushTagSendsOnlySelectedObjectAndRefusesRemoteReplacement() async throws {
        let root = try await tagFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.git")
        _ = await CommandRunner.run(command: "git init -q --bare \(Shell.quote(remote.path)) && git remote add origin \(Shell.quote(remote.path))", cwd: root.path)
        _ = await GitService.createTag("selected", message: "annotated", at: root.path)
        _ = await GitService.createTag("not-selected", at: root.path)
        let value = await GitService.tagDetails("selected", at: root.path)
        let selected = try XCTUnwrap(value)
        let pushed = await GitService.pushTag(selected, remote: "origin", at: root.path)
        XCTAssertEqual(pushed.status, 0, pushed.output)
        let remoteTags = await GitService.tags(at: remote.path)
        XCTAssertEqual(remoteTags, ["selected"])
        let remoteValue = await GitService.tagDetails("selected", at: remote.path)
        XCTAssertEqual(remoteValue?.objectID, selected.objectID)
        _ = await CommandRunner.run(command: "git tag -f selected HEAD^", cwd: root.path)
        let movedValue = await GitService.tagDetails("selected", at: root.path)
        let moved = try XCTUnwrap(movedValue)
        let stale = await GitService.pushTag(selected, remote: "origin", at: root.path)
        XCTAssertNotEqual(stale.status, 0)
        let replaced = await GitService.pushTag(moved, remote: "origin", at: root.path)
        XCTAssertNotEqual(replaced.status, 0)
        let retained = await GitService.tagDetails("selected", at: remote.path)
        XCTAssertEqual(retained?.objectID, selected.objectID)
    }

    func testPreviewCacheInvalidatesExternalEditsAndAtomicReplacement() async throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".preview-cache-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        let cache = PreviewCache()
        try Data("first".utf8).write(to: file)
        let revision = FileRevision.read(file.path)
        await cache.insert(FilePreviewDocument(text: "first"), for: file.path, revision: revision)
        let hit = await cache.value(for: file.path)
        XCTAssertEqual(hit?.text, "first")
        try Data("external change".utf8).write(to: file, options: .atomic)
        let miss = await cache.value(for: file.path)
        XCTAssertNil(miss)
        await cache.insert(FilePreviewDocument(text: "stale"), for: file.path, revision: revision)
        let refused = await cache.value(for: file.path)
        XCTAssertNil(refused)
        await cache.insert(FilePreviewDocument(text: "external change"), for: file.path, revision: FileRevision.read(file.path))
        try FileManager.default.removeItem(at: file)
        let deleted = await cache.value(for: file.path)
        XCTAssertNil(deleted)
    }

    func testFileTreeRefreshKeepsStableIDsAndNaturalOrder() throws {
        let root = workspaceRoot.appendingPathComponent(".git-tree-refresh-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["file10.txt", "file2.txt"] { try Data().write(to: root.appendingPathComponent(name)) }
        let initial = FileTreeLoader.load(url: root)
        let refreshed = FileTreeLoader.load(url: root)
        XCTAssertEqual(initial.map(\.id), refreshed.map(\.id))
        XCTAssertEqual(initial.map(\.name), ["directory", "file2.txt", "file10.txt"])
        try Data().write(to: root.appendingPathComponent("directory/new.txt"))
        let children = FileTreeLoader.load(url: root.appendingPathComponent("directory"))
        XCTAssertEqual(children.map(\.name), ["new.txt"])
        XCTAssertTrue(initial.first?.children.isEmpty == true)
    }

    func testPreviewBoundsMinifiedLinesWithoutChangingNormalCode() {
        let regular = "let value = 42\nprint(value)\n"
        XCTAssertEqual(PreviewLinePolicy.lines(in: regular).joined(separator: "\n"), regular)
        let minified = String(repeating: "a", count: 1_000_000)
        let lines = PreviewLinePolicy.lines(in: minified)
        XCTAssertEqual(lines.count, 1)
        XCTAssertLessThan(lines[0].utf8.count, 33_000)
        XCTAssertTrue(lines[0].contains("Long line"))
        let manyLines = PreviewLinePolicy.lines(in: String(repeating: "\n", count: 150_000))
        XCTAssertLessThanOrEqual(manyLines.count, PreviewLinePolicy.maximumLines + 1)
        XCTAssertTrue(manyLines.last?.contains("100,000") == true)
    }

    @MainActor
    func testUnbornUnstagePreservesEditsMadeAfterStaging() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-unborn-edit-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git init -q", cwd: root.path)
        try Data("staged".utf8).write(to: root.appendingPathComponent("file.txt"))
        _ = await GitService.fileAction(.stage, path: "file.txt", at: root.path)
        try Data("later edits".utf8).write(to: root.appendingPathComponent("file.txt"))
        let result = await GitService.fileAction(.unstage, path: "file.txt", at: root.path)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "later edits")
        _ = await GitService.fileAction(.stage, path: "file.txt", at: root.path)
        try Data("even newer edits".utf8).write(to: root.appendingPathComponent("file.txt"))
        let all = await GitService.perform(.unstageAll, at: root.path)
        XCTAssertEqual(all.status, 0, all.output)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "even newer edits")
        let status = await GitService.status(at: root.path)
        XCTAssertEqual(status.changes.first?.state, "??")
    }

    @MainActor
    func testUnstageRenameIncludesOriginalAndNewPaths() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-rename-unstage-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git init -q && git config user.name Test && git config user.email test@example.com && printf contents > original.txt && git add . && git commit -qm initial && git mv original.txt renamed.txt", cwd: root.path)
        let status = await GitService.status(at: root.path)
        let rename = try XCTUnwrap(status.changes.first(where: { $0.path == "renamed.txt" }))
        XCTAssertEqual(rename.originalPath, "original.txt")
        let result = await GitService.fileAction(.unstage, path: rename.path, at: root.path, originalPath: rename.originalPath)
        XCTAssertEqual(result.status, 0, result.output)
        let staged = await CommandRunner.run(command: "git diff --cached --name-only", cwd: root.path)
        XCTAssertTrue(staged.output.isEmpty)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("renamed.txt")), "contents")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("original.txt").path))
    }

    @MainActor
    func testUnstageAllKeepsUnresolvedConflictStages() async throws {
        let root = try await conflictFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = await GitService.conflictSnapshot("file.txt", at: root.path)
        let result = await GitService.perform(.unstageAll, at: root.path)
        XCTAssertNotEqual(result.status, 0)
        let final = await GitService.conflictSnapshot("file.txt", at: root.path)
        XCTAssertEqual(final.indexState, initial.indexState)
        XCTAssertEqual(final.originalData, initial.originalData)
    }

    @MainActor
    func testStopAllAlsoStopsCommandsWithoutProjectID() async throws {
        let firstID = UUID(); let secondID = UUID()
        let first = Task { await CommandRunner.run(command: "sleep 5", cwd: workspaceRoot.path, taskID: firstID) }
        let second = Task { await CommandRunner.run(command: "sleep 5", cwd: workspaceRoot.path, taskID: secondID) }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(CommandRunner.hasRunningCommands)
        CommandRunner.stopAll()
        let resultA = await first.value; let resultB = await second.value
        XCTAssertNotEqual(resultA.status, 0); XCTAssertNotEqual(resultB.status, 0)
        XCTAssertFalse(CommandRunner.hasRunningCommands)
    }

    @MainActor
    func testReflogRecoversUnreachableCommitWithoutChangingWorktree() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-reflog-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf initial > file.txt && git add . && git commit -qm initial && printf saved > file.txt && git add . && git commit -qm 'recover | this commit'", cwd: root.path)
        XCTAssertEqual(setup.status, 0)
        let hash = await CommandRunner.run(command: "git rev-parse HEAD", cwd: root.path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await GitService.reset("HEAD~1", mode: "--hard", at: root.path)
        try Data("working changes".utf8).write(to: root.appendingPathComponent("file.txt"))
        let page = await GitService.reflogPage(at: root.path)
        XCTAssertNil(page.failure)
        let log = page.entries
        XCTAssertTrue(log.contains(where: { $0.hash == hash && $0.subject.contains("recover | this commit") }))
        XCTAssertTrue(log.allSatisfy { $0.hash.count == 40 && !$0.selector.isEmpty })
        let recovered = await GitService.createBranch("recovered", checkout: false, from: hash, at: root.path)
        XCTAssertEqual(recovered.status, 0, recovered.output)
        let recoveredHash = await CommandRunner.run(command: "git rev-parse recovered", cwd: root.path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(recoveredHash, hash)
        let status = await GitService.status(at: root.path)
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "working changes")
    }

    @MainActor
    func testPartialStagingPreservesNoFinalNewline() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-hunk-newline-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git init -q && git config user.name Test && git config user.email test@example.com && printf old > file.txt && git add . && git commit -qm initial", cwd: root.path)
        try Data("new".utf8).write(to: root.appendingPathComponent("file.txt"))
        let diff = await GitService.diff("file.txt", at: root.path)
        XCTAssertTrue(GitDiffDocument(diff).supportsPartialIndex)
        let staged = await GitService.applyIndexHunk(file: "file.txt", hunk: 0, staged: false, expectedDiff: diff, at: root.path)
        XCTAssertEqual(staged.status, 0, staged.output)
        let content = await CommandRunner.run(command: "git show :file.txt", cwd: root.path)
        XCTAssertEqual(content.output, "new")
        let indexDiff = await GitService.diff("file.txt", at: root.path, staged: true)
        let unstaged = await GitService.applyIndexHunk(file: "file.txt", hunk: 0, staged: true, expectedDiff: indexDiff, at: root.path)
        XCTAssertEqual(unstaged.status, 0, unstaged.output)
        let original = await CommandRunner.run(command: "git show :file.txt", cwd: root.path)
        XCTAssertEqual(original.output, "old")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "new")
    }

    @MainActor
    func testPartialStagingOnlyChangesChosenHunkAndLeavesWorktreeIntact() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-hunk-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com", cwd: root.path)
        let file = "中文 [x].txt"
        let base = (1...50).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try Data(base.utf8).write(to: root.appendingPathComponent(file))
        _ = await CommandRunner.run(command: "git add . && git commit -qm initial", cwd: root.path)
        let changed = base.replacingOccurrences(of: "line 3\n", with: "first changed\nextra line\n").replacingOccurrences(of: "line 40\n", with: "second changed\n")
        try Data(changed.utf8).write(to: root.appendingPathComponent(file))
        let diff = await GitService.diff(file, at: root.path)
        let document = GitDiffDocument(diff)
        XCTAssertTrue(document.supportsPartialIndex)
        XCTAssertEqual(document.hunks.count, 2)
        let staged = await GitService.applyIndexHunk(file: file, hunk: 1, staged: false, expectedDiff: diff, at: root.path)
        XCTAssertEqual(staged.status, 0, staged.output)
        let indexDiff = await GitService.diff(file, at: root.path, staged: true)
        XCTAssertTrue(indexDiff.contains("+second changed"))
        XCTAssertFalse(indexDiff.contains("+first changed"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(file)), changed)
        let status = await GitService.status(at: root.path)
        XCTAssertEqual(status.changes.first?.state, "MM")
        let stale = await GitService.applyIndexHunk(file: file, hunk: 0, staged: false, expectedDiff: diff, at: root.path)
        XCTAssertNotEqual(stale.status, 0)
        let unstaged = await GitService.applyIndexHunk(file: file, hunk: 0, staged: true, expectedDiff: indexDiff, at: root.path)
        XCTAssertEqual(unstaged.status, 0, unstaged.output)
        let emptyIndex = await GitService.diff(file, at: root.path, staged: true)
        XCTAssertTrue(emptyIndex.isEmpty)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(file)), changed)
        let fresh = await GitService.diff(file, at: root.path)
        let first = await GitService.applyIndexHunk(file: file, hunk: 0, staged: false, expectedDiff: fresh, at: root.path)
        XCTAssertEqual(first.status, 0, first.output)
        let firstDiff = await GitService.diff(file, at: root.path, staged: true)
        XCTAssertTrue(firstDiff.contains("+first changed"))
        XCTAssertTrue(firstDiff.contains("+extra line"))
        XCTAssertFalse(firstDiff.contains("+second changed"))
    }

    func testDiffPresentationPreservesEveryHunkWithUniqueRowIdentity() {
        let source = "diff --git a/file b/file\n--- a/file\n+++ b/file\n@@ -2,3 +2,3 @@\n before\n-old first\n+new first\n after\n@@ -39,3 +39,3 @@\n before second\n-old second\n+new second\n after second\n"
        let presentation = GitDiffPresentation(source)
        XCTAssertEqual(presentation.document.hunks.count, 2)
        XCTAssertEqual(presentation.splitRows.count, 8)
        XCTAssertEqual(presentation.unifiedRows.count, 10)
        XCTAssertEqual(Set(presentation.splitRows.map(\.id)).count, presentation.splitRows.count)
        XCTAssertEqual(Set(presentation.unifiedRows.map(\.id)).count, presentation.unifiedRows.count)
        let secondRows = presentation.splitRows.filter { $0.hunk == 1 }.compactMap { row -> GitSplitDiffRow? in
            if case .split(let value) = row.content { return value }
            return nil
        }
        XCTAssertEqual(secondRows.map(\.newText), ["before second", "new second", "after second"])
        XCTAssertEqual(secondRows.map(\.newLine), [39, 40, 41])
    }

    func testSplitDiffAlignsReplacementAndPreservesLineNumbers() throws {
        let diff = "diff --git a/file b/file\nindex abc..def 100644\n--- a/file\n+++ b/file\n@@ -3,3 +3,4 @@\n context\n-old\n+new one\n+new two\n tail\n"
        let document = GitDiffDocument(diff)
        let hunk = try XCTUnwrap(document.hunks.first)
        let rows = GitSplitDiffRow.rows(hunk)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[1].oldText, "old")
        XCTAssertEqual(rows[1].newText, "new one")
        XCTAssertEqual(rows[1].oldLine, 4)
        XCTAssertEqual(rows[1].newLine, 4)
        XCTAssertNil(rows[2].oldLine)
        XCTAssertEqual(rows[2].newText, "new two")
        XCTAssertEqual(rows[3].oldLine, 5)
        XCTAssertEqual(rows[3].newLine, 6)
        XCTAssertFalse(GitDiffDocument(diff.replacingOccurrences(of: "--- a/file", with: "--- /dev/null")).supportsPartialIndex)
    }

    @MainActor
    func testSyntaxColoringKeepsCommentsInsideStringsAndPlainText() throws {
        let code = "let url = \"https://example.com/return42\" // comment"
        let value = SyntaxHighlighter.attributed(code, language: "swift", search: "example")
        let source = code as NSString
        func color(_ needle: String) -> NSColor? { value.attribute(.foregroundColor, at: source.range(of: needle).location, effectiveRange: nil) as? NSColor }
        XCTAssertEqual(color("let"), SyntaxPalette.keyword)
        XCTAssertEqual(color("https"), SyntaxPalette.string)
        XCTAssertEqual(color("return42"), SyntaxPalette.string)
        XCTAssertEqual(color("comment"), SyntaxPalette.comment)
        XCTAssertNotNil(value.attribute(.backgroundColor, at: source.range(of: "example").location, effectiveRange: nil))
        let shell = "VALUE=\"#literal\" # actual"
        let shellColors = SyntaxHighlighter.attributed(shell, language: "sh")
        XCTAssertEqual(shellColors.attribute(.foregroundColor, at: (shell as NSString).range(of: "#literal").location, effectiveRange: nil) as? NSColor, SyntaxPalette.string)
        let plain = SyntaxHighlighter.attributed("return 42", language: "txt")
        XCTAssertEqual(plain.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, NSColor.labelColor)
    }

    @MainActor
    func testSelectedRunConfigurationUsesWorkingDirectoryAndEnvironment() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-run-config-test-" + UUID().uuidString)
        let directory = root.appendingPathComponent("working directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkbenchModel(restoringSession: false)
        let project = Project(name: "fixture", path: root.path)
        model.projects = [project]; model.selectedProjectID = project.id
        var config = RunConfiguration(name: "first", command: "printf '%s:%s' \"$GW_RUN_VALUE\" \"$PWD\"", workingDirectory: directory.path, environment: ["GW_RUN_VALUE": "configured"])
        XCTAssertTrue(model.replaceRunConfigurations([config], selectedID: config.id, projectID: project.id))
        config.name = "renamed"
        XCTAssertTrue(model.replaceRunConfigurations([config], selectedID: config.id, projectID: project.id))
        let data = try Data(contentsOf: root.appendingPathComponent(".git-workbench/run-config.json"))
        let saved = try JSONDecoder().decode([RunConfiguration].self, from: data)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.id, config.id)
        XCTAssertEqual(saved.first?.name, "renamed")
        model.runCommand()
        for _ in 0..<300 {
            if let tasks = model.runningTasks[project.id], tasks.contains(where: { !$0.isRunning }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let task = try XCTUnwrap(model.runningTasks[project.id]?.first)
        XCTAssertFalse(task.isRunning)
        XCTAssertEqual(task.exitCode, 0)
        XCTAssertTrue(task.output.hasSuffix("configured:" + directory.path), task.output)
    }

    @MainActor
    func testBackgroundProjectOutputDoesNotReplaceActiveConsole() async throws {
        let model = WorkbenchModel(restoringSession: false)
        let first = Project(name: "first", path: workspaceRoot.path)
        let second = Project(name: "second", path: workspaceRoot.path)
        model.projects = [first, second]; model.selectedProjectID = first.id
        model.runCommand(command: "sleep 0.1; printf first-output")
        model.selectedProjectID = second.id
        model.commandOutput = "second-console"
        for _ in 0..<300 {
            if let tasks = model.runningTasks[first.id], tasks.contains(where: { !$0.isRunning }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.commandOutput, "second-console")
        XCTAssertEqual(model.projects.first?.output, "first-output")
        XCTAssertEqual(model.runningTasks[first.id]?.first?.exitCode, 0)
    }

    @MainActor
    func testRemoteURLsPreserveSpaces() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-remote-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git init -q", cwd: root.path)
        let url = root.appendingPathComponent("repository with spaces.git").path
        let added = await GitService.remoteAction(.add, name: "origin", url: url, at: root.path)
        XCTAssertEqual(added.status, 0)
        let remotes = await GitService.remotes(at: root.path)
        XCTAssertEqual(remotes.first?.fetchURL, url)
        XCTAssertEqual(remotes.first?.pushURL, url)
    }

    @MainActor
    func testInteractiveCommandLoadsShellConfigurationAndKeepsRunOverrides() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-shell-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("export GW_FIXTURE_VALUE=from_profile\nfixture_command() { printf 'from_fixture_command'; }\n".utf8).write(to: root.appendingPathComponent(".zshrc"))
        let result = await CommandRunner.run(command: "fixture_command; printf ':%s' \"$GW_FIXTURE_VALUE\"", cwd: root.path, environment: ["ZDOTDIR": root.path, "GW_FIXTURE_VALUE": "run override"], interactiveShell: true)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "from_fixture_command:run override")
    }

    @MainActor
    func testCommandTimeoutEndsHungProbe() async {
        let result = await CommandRunner.run(command: "sleep 5", cwd: workspaceRoot.path, timeoutSeconds: 0.05)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Command timed out"))
    }

    func testEnvironmentProbeParserIgnoresShellStartupText() {
        let parsed = EnvironmentDetector.parse("startup banner\n\u{001e}node\u{001f}/fixture/bin/node\n\u{001f}v24.0.0\n\u{001e}\u{001e}java\u{001f}\u{001f}\u{001e}")
        XCTAssertEqual(parsed.first(where: { $0.name == "node" })?.path, "/fixture/bin/node")
        XCTAssertEqual(parsed.first(where: { $0.name == "node" })?.version, "v24.0.0")
        XCTAssertTrue(parsed.first(where: { $0.name == "node" })?.available == true)
        XCTAssertTrue(parsed.first(where: { $0.name == "java" })?.available == false)
        XCTAssertEqual(parsed.count, EnvironmentDetector.tools.count)
    }

    @MainActor
    func testConflictWorkflowSupportsRebaseAndCherryPickContinuation() async throws {
        for state in [GitOperationState.rebasing, .cherryPicking] {
            let root = try await conflictFixture()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = await GitService.mergeAbort(at: root.path)
            let command = state == .rebasing ? "git rebase incoming" : "git cherry-pick incoming"
            let started = await CommandRunner.run(command: command, cwd: root.path, environment: ["GIT_EDITOR": "true"])
            XCTAssertNotEqual(started.status, 0)
            let operation = await GitService.operationState(at: root.path)
            XCTAssertEqual(operation, state)
            let snapshot = await GitService.conflictSnapshot("file.txt", at: root.path)
            XCTAssertEqual(snapshot.ours, state == .rebasing ? "incoming\n" : "current\n")
            XCTAssertEqual(snapshot.theirs, state == .rebasing ? "current\n" : "incoming\n")
            let saved = await GitService.saveConflict("file.txt", result: "combined\n", snapshot: snapshot, at: root.path)
            XCTAssertEqual(saved.status, 0, saved.output)
            let continued = await GitService.continueOperation(state, at: root.path)
            XCTAssertEqual(continued.status, 0, continued.output)
            let final = await GitService.operationState(at: root.path)
            XCTAssertNil(final)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "combined\n")
        }
    }

    @MainActor
    func testCommitGraphIncludesParentsAndOtherBranches() async throws {
        let root = try await conflictFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = await GitService.conflictSnapshot("file.txt", at: root.path)
        _ = await GitService.saveConflict("file.txt", result: "combined\n", snapshot: snapshot, at: root.path)
        _ = await GitService.continueOperation(.merging, at: root.path)
        let merged = await GitService.commits(at: root.path)
        XCTAssertEqual(merged.first?.parents.count, 2)
        XCTAssertTrue(merged.first?.refs.contains(where: { $0.contains("main") }) == true)
        let graph = GitGraphLayout.rows(merged)
        let head = try XCTUnwrap(merged.first)
        XCTAssertEqual(graph[head.hash]?.parents.count, 2)
        XCTAssertEqual(Set(graph[head.hash]?.parents ?? []).count, 2)
        let initial = try XCTUnwrap(merged.last)
        XCTAssertTrue(initial.parents.isEmpty)
        XCTAssertTrue(graph[initial.hash]?.parents.isEmpty == true)
        _ = await CommandRunner.run(command: "git checkout -qb another && printf other > other.txt && git add . && git commit -qm other-only && git checkout -q main", cwd: root.path)
        let current = await GitService.commits(at: root.path)
        XCTAssertFalse(current.contains(where: { $0.subject == "other-only" }))
        let all = await GitService.commits(at: root.path, allBranches: true)
        XCTAssertTrue(all.contains(where: { $0.subject == "other-only" }))
        let badReset = await GitService.reset("--hard", mode: "--mixed", at: root.path)
        XCTAssertNotEqual(badReset.status, 0)
        let badRevert = await GitService.revert("--abort", at: root.path)
        XCTAssertNotEqual(badRevert.status, 0)
    }

    @MainActor
    func testHTTPCloneUsesTemporaryAskpassCredentials() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-auth-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf auth-content > file.txt && git add . && git commit -qm initial && git update-server-info", cwd: source.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        let script = root.appendingPathComponent("server.py")
        let portFile = root.appendingPathComponent("port")
        let python = """
        import base64, http.server, os, sys
        os.chdir(sys.argv[1])
        expected = 'Basic ' + base64.b64encode(b'test-user:test-token').decode()
        class Handler(http.server.SimpleHTTPRequestHandler):
            def do_GET(self):
                if self.headers.get('Authorization') != expected:
                    self.send_response(401)
                    self.send_header('WWW-Authenticate', 'Basic realm="CodeFlight test"')
                    self.end_headers()
                    return
                super().do_GET()
            def log_message(self, *args):
                pass
        server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        with open(sys.argv[2], 'w') as output:
            output.write(str(server.server_port))
        server.serve_forever()
        """
        try Data(python.utf8).write(to: script)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", script.path, source.appendingPathComponent(".git").path, portFile.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        var port: String?
        for _ in 0..<200 {
            if let value = try? String(contentsOf: portFile, encoding: .utf8), !value.isEmpty { port = value; break }
            if !server.isRunning { throw XCTSkip("Python HTTP fixture could not start") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let readyPort = try XCTUnwrap(port)
        let remote = "http://127.0.0.1:" + readyPort
        let request = GitCloneRequest(remote: remote, parent: root.path, directory: "cloned")
        let credentials = GitCredentials(username: "test-user", secret: "test-token")
        XCTAssertFalse(credentials.git.contains(credentials.secret))
        XCTAssertTrue(credentials.git.contains("credential.helper="))
        let result = await GitService.clone(request, taskID: UUID(), credentials: credentials)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(result.output.contains(credentials.secret))
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: request.destination).appendingPathComponent("file.txt")), "auth-content")
        let config = await CommandRunner.run(command: "git config --local --list", cwd: request.destination)
        XCTAssertFalse(config.output.contains(credentials.secret))
        XCTAssertFalse(config.output.contains(credentials.username))
    }

    @MainActor
    func testStoppingCommandTerminatesDescendantsIncludingIgnoredTermSignal() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-process-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        let taskID = UUID()
        let script = "trap '' TERM; echo $$ > " + Shell.quote(pidFile.path) + "; while true; do sleep 1; done"
        let running = Task { await CommandRunner.run(command: "/bin/sh -c " + Shell.quote(script) + " & wait", cwd: root.path, taskID: taskID) }
        var pid: Int32?
        for _ in 0..<100 {
            if let value = try? String(contentsOf: pidFile, encoding: .utf8), let number = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) { pid = number; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let child = try XCTUnwrap(pid)
        defer { kill(child, SIGKILL) }
        XCTAssertEqual(kill(child, 0), 0)
        CommandRunner.stop(taskID: taskID)
        let result = await running.value
        XCTAssertNotEqual(result.status, 0)
        // A killed orphan may briefly remain a zombie until launchd reaps it.
        let state = await CommandRunner.run(command: "ps -o stat= -p \(child)", cwd: root.path)
        XCTAssertTrue(state.status != 0 || state.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z"), state.output)
    }

    @MainActor
    func testStashPreviewIncludesUntrackedAndRejectsStaleReferences() async throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".git-stash-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf base > file.txt && git add . && git commit -qm initial", cwd: root.path)
        try Data("changed\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        try Data("new content\n".utf8).write(to: root.appendingPathComponent("new.txt"))
        let saved = await GitService.saveStash(message: "中文 | first", includeUntracked: true, keepIndex: false, at: root.path)
        XCTAssertEqual(saved.status, 0, saved.output)
        let list = await GitService.stashes(at: root.path)
        XCTAssertEqual(list.count, 1)
        let first = try XCTUnwrap(list.first)
        XCTAssertEqual(first.reference, "stash@{0}")
        XCTAssertEqual(first.hash.count, 40)
        XCTAssertTrue(first.message.contains("中文 | first"))
        let preview = await GitService.stashDiff(first, at: root.path)
        XCTAssertTrue(preview.contains("+changed"))
        XCTAssertTrue(preview.contains("+new content"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("new.txt").path))
        try Data("second\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        _ = await GitService.saveStash(message: "second", includeUntracked: false, keepIndex: false, at: root.path)
        let stale = await GitService.stashAction(.drop, stash: first, at: root.path)
        XCTAssertNotEqual(stale.status, 0)
        let refreshed = await GitService.stashes(at: root.path)
        XCTAssertEqual(refreshed.count, 2)
        let relocated = try XCTUnwrap(refreshed.first(where: { $0.hash == first.hash }))
        let applied = await GitService.stashAction(.apply, stash: relocated, at: root.path)
        XCTAssertEqual(applied.status, 0, applied.output)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("new.txt")), "new content\n")
        let retained = await GitService.stashes(at: root.path)
        XCTAssertEqual(retained.count, 2)
        let dropped = await GitService.stashAction(.drop, stash: relocated, at: root.path)
        XCTAssertEqual(dropped.status, 0, dropped.output)
        let remaining = await GitService.stashes(at: root.path)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue(remaining[0].message.contains("second"))
    }

    @MainActor
    func testCloneCreatesRepositoryAndRejectsExistingDestination() async throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".git-clone-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf content > tracked.txt && git add . && git commit -qm initial", cwd: source.path)
        let request = GitCloneRequest(remote: source.path, parent: root.path, directory: "cloned project")
        XCTAssertNil(request.validationError)
        let result = await GitService.clone(request, taskID: UUID())
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: request.destination).appendingPathComponent("tracked.txt")), "content")
        let status = await GitService.status(at: request.destination)
        XCTAssertEqual(status.branch, "main")
        XCTAssertTrue(status.changes.isEmpty)
        let duplicate = await GitService.clone(request, taskID: UUID())
        XCTAssertNotEqual(duplicate.status, 0)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: request.destination).appendingPathComponent("tracked.txt")), "content")
        XCTAssertNotNil(GitCloneRequest(remote: "https://name:secret@example.com/repo.git", parent: root.path, directory: "other").validationError)
        XCTAssertNotNil(GitCloneRequest(remote: source.path, parent: root.path, directory: "../outside").validationError)
        XCTAssertEqual(GitCloneRequest.suggestedDirectory("git@example.com:team/project.git"), "project")
    }

    @MainActor
    func testFileActionsTreatSpecialPathCharactersLiterally() async throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".git-literal-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git init -q && git config user.name Test && git config user.email test@example.com", cwd: root.path)
        for file in ["[x].txt", "x.txt"] { try Data("base\n".utf8).write(to: root.appendingPathComponent(file)) }
        _ = await CommandRunner.run(command: "git add . && git commit -qm initial", cwd: root.path)
        for file in ["[x].txt", "x.txt"] { try Data("changed \(file)\n".utf8).write(to: root.appendingPathComponent(file)) }
        let staged = await GitService.fileAction(.stage, path: "[x].txt", at: root.path)
        XCTAssertEqual(staged.status, 0)
        let status = await GitService.status(at: root.path)
        XCTAssertEqual(status.changes.first(where: { $0.path == "[x].txt" })?.state, "M ")
        XCTAssertEqual(status.changes.first(where: { $0.path == "x.txt" })?.state, " M")
        let unstage = await GitService.fileAction(.unstage, path: "[x].txt", at: root.path)
        XCTAssertEqual(unstage.status, 0)
        let discard = await GitService.fileAction(.discard, path: "[x].txt", at: root.path)
        XCTAssertEqual(discard.status, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("[x].txt")), "base\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("x.txt")), "changed x.txt\n")
    }

    @MainActor
    func testCommandOutputReportsTruncationWithoutLosingUnicodeOutput() async {
        let output = await CommandRunner.run(command: "printf '中文abcdef'", cwd: "/", outputLimit: 7)
        XCTAssertEqual(output.status, 0)
        XCTAssertTrue(output.truncated)
        XCTAssertTrue(output.output.hasSuffix("abcdef"))
        XCTAssertFalse(output.output.isEmpty)
    }

    @MainActor
    func testStatusPreservesLargeChangeLists() async throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".git-status-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git init -q -b large.status", cwd: root.path)
        for index in 0..<2100 {
            let name = String(repeating: "a", count: 130) + "-\(index).txt"
            FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data())
        }
        let status = await GitService.status(at: root.path)
        XCTAssertEqual(status.branch, "large.status")
        XCTAssertNil(status.error)
        XCTAssertEqual(status.changes.count, 2100)
    }

    @MainActor
    private func conflictFixture(deletingTheirs: Bool = false) async throws -> URL {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".git-conflict-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf 'base\\n' > file.txt && git add . && git commit -qm initial && git checkout -qb incoming", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        if deletingTheirs { try FileManager.default.removeItem(at: root.appendingPathComponent("file.txt")) }
        else { try Data("incoming\n".utf8).write(to: root.appendingPathComponent("file.txt")) }
        let theirs = await CommandRunner.run(command: "git add -A && git commit -qm incoming && git checkout -q main", cwd: root.path)
        XCTAssertEqual(theirs.status, 0, theirs.output)
        try Data("current\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        let ours = await CommandRunner.run(command: "git add . && git commit -qm current && git merge incoming --no-edit", cwd: root.path)
        XCTAssertNotEqual(ours.status, 0)
        return root
    }

    @MainActor
    func testConflictEditorSnapshotSaveAndContinue() async throws {
        let root = try await conflictFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = await GitService.conflictSnapshot("file.txt", at: root.path)
        XCTAssertTrue(snapshot.editable)
        XCTAssertEqual(snapshot.base, "base\n")
        XCTAssertEqual(snapshot.ours, "current\n")
        XCTAssertEqual(snapshot.theirs, "incoming\n")
        XCTAssertTrue(GitService.containsConflictMarkers(snapshot.working))
        let operation = await GitService.operationState(at: root.path)
        XCTAssertEqual(operation, .merging)
        let blocked = await GitService.saveConflict("file.txt", result: snapshot.working, snapshot: snapshot, at: root.path)
        XCTAssertNotEqual(blocked.status, 0)
        let unresolved = await GitService.markConflictResolved("file.txt", at: root.path)
        XCTAssertNotEqual(unresolved.status, 0)
        let saved = await GitService.saveConflict("file.txt", result: "current + incoming\n", snapshot: snapshot, at: root.path)
        XCTAssertEqual(saved.status, 0, saved.output)
        let status = await GitService.status(at: root.path)
        XCTAssertFalse(status.changes.contains(where: \.isConflicted))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "current + incoming\n")
        let continued = await GitService.continueOperation(.merging, at: root.path)
        XCTAssertEqual(continued.status, 0, continued.output)
        let finished = await GitService.operationState(at: root.path)
        XCTAssertNil(finished)
        let parents = await CommandRunner.run(command: "git rev-list --parents -n 1 HEAD", cwd: root.path)
        XCTAssertEqual(parents.output.split(whereSeparator: \.isWhitespace).count, 3)
    }

    @MainActor
    func testConflictSaveRefusesExternalChangesAndStaleIndex() async throws {
        let root = try await conflictFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = await GitService.conflictSnapshot("file.txt", at: root.path)
        try Data("external edit\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        let refused = await GitService.saveConflict("file.txt", result: "my result\n", snapshot: snapshot, at: root.path)
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "external edit\n")
        let external = await GitService.markConflictResolved("file.txt", at: root.path)
        XCTAssertEqual(external.status, 0, external.output)
        let stale = await GitService.saveConflict("file.txt", result: "stale result\n", snapshot: snapshot, at: root.path)
        XCTAssertNotEqual(stale.status, 0)
        let staleSide = await GitService.resolve("file.txt", side: .theirs, at: root.path)
        XCTAssertNotEqual(staleSide.status, 0)
        let staleMark = await GitService.markConflictResolved("file.txt", at: root.path)
        XCTAssertNotEqual(staleMark.status, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "external edit\n")
    }

    @MainActor
    func testModifyDeleteConflictAcceptsMissingSide() async throws {
        let root = try await conflictFixture(deletingTheirs: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = await GitService.conflictSnapshot("file.txt", at: root.path)
        XCTAssertTrue(snapshot.editable)
        XCTAssertNil(snapshot.theirs)
        XCTAssertEqual(snapshot.ours, "current\n")
        let result = await GitService.resolve("file.txt", side: .theirs, at: root.path)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("file.txt").path))
        let continued = await GitService.continueOperation(.merging, at: root.path)
        XCTAssertEqual(continued.status, 0, continued.output)
    }

    @MainActor
    func testConflictEditorRejectsBinaryAndOversizeDiskFiles() async throws {
        let root = try await conflictFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("file.txt"))
        let binary = await GitService.conflictSnapshot("file.txt", at: root.path)
        XCTAssertFalse(binary.editable)
        try Data(repeating: 65, count: GitConflictSnapshot.byteLimit + 1).write(to: root.appendingPathComponent("file.txt"))
        let large = await GitService.conflictSnapshot("file.txt", at: root.path)
        XCTAssertFalse(large.editable)
        XCTAssertNil(large.originalData)
        let side = await GitService.resolve("file.txt", side: .ours, at: root.path)
        XCTAssertEqual(side.status, 0, side.output)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "current\n")
    }

    @MainActor
    func testEmptyRepositoryStagingDiffAndUnstage() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-workbench-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git init -q -b release.1", cwd: root.path)
        try Data("first version\n".utf8).write(to: root.appendingPathComponent("new file.txt"))
        let initial = await GitService.status(at: root.path)
        XCTAssertTrue(initial.isRepository)
        XCTAssertEqual(initial.branch, "release.1")
        XCTAssertEqual(initial.changes.first?.state, "??")
        let untracked = await GitService.diff("new file.txt", at: root.path, untracked: true)
        XCTAssertTrue(untracked.contains("+first version"))
        let stage = await GitService.fileAction(.stage, path: "new file.txt", at: root.path)
        XCTAssertEqual(stage.status, 0)
        let staged = await GitService.diff("new file.txt", at: root.path, staged: true)
        XCTAssertTrue(staged.contains("+first version"))
        let unstage = await GitService.fileAction(.unstage, path: "new file.txt", at: root.path)
        XCTAssertEqual(unstage.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("new file.txt").path))
        _ = await GitService.perform(.stageAll, at: root.path)
        let unstageAll = await GitService.perform(.unstageAll, at: root.path)
        XCTAssertEqual(unstageAll.status, 0)
        let final = await GitService.status(at: root.path)
        XCTAssertEqual(final.changes.first?.state, "??")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("nested\n".utf8).write(to: root.appendingPathComponent("src/nested.swift"))
        let nested = await GitService.status(at: root.path)
        XCTAssertTrue(nested.changes.contains(where: { $0.path == "src/nested.swift" && $0.state == "??" }))
    }

    @MainActor
    func testIndexDiffIsSeparateFromWorkingTreeDiff() async throws {
        let root = workspaceRoot.appendingPathComponent(".git-workbench-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git init -q && git config user.name Test && git config user.email test@example.com && printf 'base\\n' > file.txt && git add . && git commit -qm initial", cwd: root.path)
        try Data("index version\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        _ = await GitService.fileAction(.stage, path: "file.txt", at: root.path)
        try Data("working version\n".utf8).write(to: root.appendingPathComponent("file.txt"))
        let index = await GitService.diff("file.txt", at: root.path, staged: true)
        let worktree = await GitService.diff("file.txt", at: root.path)
        XCTAssertTrue(index.contains("+index version"))
        XCTAssertFalse(index.contains("working version"))
        XCTAssertTrue(worktree.contains("-index version"))
        XCTAssertTrue(worktree.contains("+working version"))
        XCTAssertFalse(worktree.contains("-base"))
        let status = await GitService.status(at: root.path)
        XCTAssertEqual(status.changes.first?.state, "MM")
        XCTAssertTrue(status.changes.first?.isStaged == true)
        XCTAssertTrue(status.changes.first?.isUnstaged == true)
    }

    @MainActor
    func testHistoryPaginationAndInitialCommitDetails() async throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".git-history-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git init -q && git config user.name Test && git config user.email test@example.com", cwd: root.path)
        let filename = "中文 file.txt"
        try Data("initial content\n".utf8).write(to: root.appendingPathComponent(filename))
        _ = await CommandRunner.run(command: "git add . && git commit -qm 'initial | subject'", cwd: root.path)
        try Data("updated content\n".utf8).write(to: root.appendingPathComponent(filename))
        _ = await CommandRunner.run(command: "git add . && git commit -qm 'second | subject'", cwd: root.path)
        let latest = await GitService.commits(at: root.path, limit: 1)
        let earlier = await GitService.commits(at: root.path, skip: 1, limit: 1)
        XCTAssertEqual(latest.count, 1)
        XCTAssertEqual(earlier.count, 1)
        XCTAssertEqual(latest.first?.subject, "second | subject")
        XCTAssertEqual(earlier.first?.subject, "initial | subject")
        let first = try XCTUnwrap(earlier.first)
        XCTAssertEqual(first.hash.count, 40)
        XCTAssertEqual(first.author, "Test")
        let files = await GitService.commitFiles(first.hash, at: root.path)
        XCTAssertEqual(files, [filename])
        let diff = await GitService.commitDiff(first.hash, file: filename, at: root.path)
        XCTAssertTrue(diff.contains("+initial content"))
        let description = await GitService.commitDescription(first.hash, at: root.path)
        XCTAssertTrue(description.contains("initial | subject"))
        let end = await GitService.commits(at: root.path, skip: 2)
        XCTAssertTrue(end.isEmpty)
    }

    @MainActor
    func testDiscardRestoresIndexWithoutDestroyingStagedVersion() async throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".git-discard-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git init -q && git config user.name Test && git config user.email test@example.com && printf base > file.txt && git add . && git commit -qm initial", cwd: root.path)
        try Data("staged".utf8).write(to: root.appendingPathComponent("file.txt"))
        _ = await GitService.fileAction(.stage, path: "file.txt", at: root.path)
        try Data("unstaged".utf8).write(to: root.appendingPathComponent("file.txt"))
        let result = await GitService.fileAction(.discard, path: "file.txt", at: root.path)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("file.txt")), "staged")
        let status = await GitService.status(at: root.path)
        XCTAssertEqual(status.changes.first?.state, "M ")
    }

    @MainActor
    func testBranchLifecycleAndRemoteTracking() async throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".git-branch-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf base > file.txt && git add . && git commit -qm initial", cwd: root.path)
        let create = await GitService.createBranch("feature/test", checkout: true, at: root.path)
        XCTAssertEqual(create.status, 0)
        let current = await GitService.status(at: root.path)
        XCTAssertEqual(current.branch, "feature/test")
        let rename = await GitService.renameBranch("feature/test", to: "feature/renamed", at: root.path)
        XCTAssertEqual(rename.status, 0)
        _ = await GitService.checkout(branch: "main", at: root.path)
        let merge = await GitService.merge("feature/renamed", at: root.path)
        XCTAssertEqual(merge.status, 0)
        let delete = await GitService.deleteBranch("feature/renamed", at: root.path)
        XCTAssertEqual(delete.status, 0)
        // A local remote-tracking ref exercises checkout without network access.
        _ = await CommandRunner.run(command: "git remote add origin . && git update-ref refs/remotes/origin/feature/remote HEAD", cwd: root.path)
        let track = await GitService.checkoutRemote("origin/feature/remote", localName: "feature/remote", at: root.path)
        XCTAssertEqual(track.status, 0)
        let upstream = await CommandRunner.run(command: "git rev-parse --abbrev-ref '@{upstream}'", cwd: root.path)
        XCTAssertEqual(upstream.output.trimmingCharacters(in: .whitespacesAndNewlines), "origin/feature/remote")
        _ = await GitService.checkout(branch: "main", at: root.path)
        let existing = await GitService.checkoutRemote("origin/feature/remote", localName: "feature/remote", at: root.path)
        XCTAssertEqual(existing.status, 0, existing.output)
        _ = await GitService.checkout(branch: "main", at: root.path)
        _ = await CommandRunner.run(command: "git remote add other . && git update-ref refs/remotes/other/feature/remote HEAD", cwd: root.path)
        let mismatch = await GitService.checkoutRemote("other/feature/remote", localName: "feature/remote", at: root.path)
        XCTAssertNotEqual(mismatch.status, 0)
        let unchanged = await GitService.status(at: root.path)
        XCTAssertEqual(unchanged.branch, "main")
    }

    @MainActor
    func testRemoteSyncTargetsUpstreamAndPullStrategies() async throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".git-sync-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local").path
        let peer = root.appendingPathComponent("peer").path
        let setup = await CommandRunner.run(command: "git init -q --bare remote.git && git init -q -b main local && git -C local config user.name Test && git -C local config user.email test@example.com && git -C local remote add origin ../remote.git && git -C local commit --allow-empty -qm initial", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        let pushed = await GitService.push(remote: "origin", branch: "review/target", setUpstream: true, at: local)
        XCTAssertEqual(pushed.status, 0, pushed.output)
        let freshPath = root.appendingPathComponent("initial-pull").path
        _ = await CommandRunner.run(command: "git init -q -b main initial-pull && git -C initial-pull remote add origin ../remote.git", cwd: root.path)
        let firstPull = await GitService.pull(remote: "origin", branch: "review/target", strategy: .fastForward, at: freshPath)
        XCTAssertEqual(firstPull.status, 0, firstPull.output)
        let info = await GitService.syncInfo(at: local)
        XCTAssertEqual(info.branch, "main")
        XCTAssertEqual(info.remote, "origin")
        XCTAssertEqual(info.remoteBranch, "review/target")
        XCTAssertEqual(info.upstream, "origin/review/target")
        XCTAssertEqual(info.ahead, 0)
        XCTAssertEqual(info.behind, 0)
        let clone = await CommandRunner.run(command: "git clone -q -b review/target remote.git peer && git -C peer config user.name Peer && git -C peer config user.email peer@example.com && git -C peer commit --allow-empty -qm remote-first && git -C peer push -q", cwd: root.path)
        XCTAssertEqual(clone.status, 0, clone.output)
        _ = await GitService.perform(.fetch, at: local)
        let behind = await GitService.syncInfo(at: local)
        XCTAssertEqual(behind.behind, 1)
        let fastForward = await GitService.pull(remote: "origin", branch: "review/target", strategy: .fastForward, at: local)
        XCTAssertEqual(fastForward.status, 0, fastForward.output)
        _ = await CommandRunner.run(command: "git commit --allow-empty -qm local-diverged && git config pull.rebase true", cwd: local)
        _ = await CommandRunner.run(command: "git commit --allow-empty -qm remote-diverged && git push -q", cwd: peer)
        let refused = await GitService.pull(remote: "origin", branch: "review/target", strategy: .fastForward, at: local)
        XCTAssertNotEqual(refused.status, 0)
        let merged = await GitService.pull(remote: "origin", branch: "review/target", strategy: .merge, at: local)
        XCTAssertEqual(merged.status, 0, merged.output)
        let parents = await CommandRunner.run(command: "git rev-list --parents -n 1 HEAD", cwd: local)
        XCTAssertEqual(parents.output.split(whereSeparator: { $0.isWhitespace }).count, 3)
        _ = await GitService.push(remote: "origin", branch: "review/target", setUpstream: false, at: local)
        _ = await CommandRunner.run(command: "git pull -q --ff-only && git commit --allow-empty -qm remote-rebase && git push -q", cwd: peer)
        _ = await CommandRunner.run(command: "git commit --allow-empty -qm local-rebase && git config pull.ff only", cwd: local)
        let rebased = await GitService.pull(remote: "origin", branch: "review/target", strategy: .rebase, at: local)
        XCTAssertEqual(rebased.status, 0, rebased.output)
        let finalInfo = await GitService.syncInfo(at: local)
        XCTAssertEqual(finalInfo.ahead, 1)
        XCTAssertEqual(finalInfo.behind, 0)
        let invalid = await GitService.push(remote: "origin", branch: "bad branch", setUpstream: true, at: local)
        XCTAssertNotEqual(invalid.status, 0)
    }

    func testConflictsCannotBeCommittedAsStagedFiles() {
        for state in ["DD", "AU", "UD", "UA", "DU", "AA", "UU"] {
            let change = GitChange(path: "conflict", state: state)
            XCTAssertTrue(change.isConflicted)
            XCTAssertFalse(change.isStaged)
            XCTAssertTrue(change.isUnstaged)
        }
    }

    func testPreviewReadsBoundedPrefixOfLargeFile() throws {
        let url = workspaceRoot.appendingPathComponent(".git-workbench-test-" + UUID().uuidString)
        FileManager.default.createFile(atPath: url.path, contents: Data(("let value = 1\n" + String(repeating: " ", count: 8192)).utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 512 * 1024 * 1024)
        try handle.close()
        let preview = FilePreviewReader.read(path: url.path)
        XCTAssertTrue(preview.text.hasPrefix("let value = 1"))
        XCTAssertTrue(preview.truncated)
        XCTAssertLessThan(preview.text.utf8.count, FilePreviewReader.byteLimit + 200)
    }

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(Shell.quote("a'b"), "'a'\\''b'")
    }

    func testRunConfigurationDefaults() {
        let configuration = RunConfiguration(name: "dev", command: "swift run", workingDirectory: "/tmp/project")
        XCTAssertEqual(configuration.name, "dev")
        XCTAssertFalse(configuration.autoStart)
        XCTAssertTrue(configuration.environment.isEmpty)
    }

    func testEnvironmentParserSupportsShellStyleEntries() {
        let parsed = EnvironmentParser.parse("""
        # local development

        NODE_ENV=development
        export API_URL=https://example.com/a b
        TOKEN=a=b=c
        QUOTED="hello world"
        SINGLE='quoted value'
        invalid-line
        """)
        XCTAssertEqual(parsed["NODE_ENV"], "development")
        XCTAssertEqual(parsed["API_URL"], "https://example.com/a b")
        XCTAssertEqual(parsed["TOKEN"], "a=b=c")
        XCTAssertEqual(parsed["QUOTED"], "hello world")
        XCTAssertEqual(parsed["SINGLE"], "quoted value")
        XCTAssertNil(parsed["invalid-line"])
    }

    func testProjectCommandDetectorFindsNativeProjectCommands() throws {
        let directory = workspaceRoot.appendingPathComponent(".git-workbench-detector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("Package.swift"))
        try Data().write(to: directory.appendingPathComponent("pom.xml"))
        try Data().write(to: directory.appendingPathComponent("artisan"))

        let commands = ProjectCommandDetector.detect(at: directory).map(\.command)
        XCTAssertTrue(commands.contains("swift run"))
        XCTAssertTrue(commands.contains("mvn test"))
        XCTAssertTrue(commands.contains("php artisan serve"))
    }

    func testFileTreeLoadsOneDirectoryLevelAtATime() throws {
        let root = workspaceRoot.appendingPathComponent(".git-workbench-tree-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("src")
        let deeper = nested.appendingPathComponent("components")
        try FileManager.default.createDirectory(at: deeper, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("root".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("child".utf8).write(to: nested.appendingPathComponent("main.swift"))
        try Data("deep".utf8).write(to: deeper.appendingPathComponent("View.swift"))

        let rootItems = FileTreeLoader.load(url: root)
        let rootDirectory = try XCTUnwrap(rootItems.first(where: { $0.name == "src" }))
        XCTAssertTrue(rootDirectory.isDirectory)
        XCTAssertTrue(rootDirectory.children.isEmpty)

        let childItems = FileTreeLoader.load(url: nested)
        let childDirectory = try XCTUnwrap(childItems.first(where: { $0.name == "components" }))
        XCTAssertTrue(childDirectory.children.isEmpty)
        XCTAssertTrue(childItems.contains(where: { $0.name == "main.swift" }))
    }

    func testFirstFileURLFindsPreviewWhenRootContainsOnlyDirectories() throws {
        let root = workspaceRoot.appendingPathComponent(".git-workbench-first-file-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("Sources/Feature")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("preview".utf8).write(to: nested.appendingPathComponent("View.swift"))

        let result = FileTreeLoader.firstFileURL(url: root)
        XCTAssertEqual(result?.path, nested.appendingPathComponent("View.swift").path)
    }

    func testFileTreeSearchFindsNestedFilesWithoutBuildingTree() throws {
        let root = workspaceRoot.appendingPathComponent(".git-workbench-search-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("src/components")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("content".utf8).write(to: nested.appendingPathComponent("Preview.swift"))

        let results = FileTreeLoader.search(url: root, query: "preview")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "src/components/Preview.swift")
        XCTAssertTrue(results.first?.children.isEmpty == true)
    }

    func testGitChangePorcelainColumns() {
        let staged = GitChange(path: "staged.swift", state: "M ")
        let unstaged = GitChange(path: "unstaged.swift", state: " M")
        let untracked = GitChange(path: "new.swift", state: "??")
        XCTAssertTrue(staged.isStaged)
        XCTAssertFalse(staged.isUnstaged)
        XCTAssertFalse(unstaged.isStaged)
        XCTAssertTrue(unstaged.isUnstaged)
        XCTAssertFalse(untracked.isStaged)
        XCTAssertTrue(untracked.isUnstaged)
    }

    @MainActor
    func testGitStatusHandlesRenamedPath() async throws {
        let directory = workspaceRoot.appendingPathComponent(".git-workbench-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = await CommandRunner.run(command: "git init -q && git config user.email test@example.com && git config user.name Test && printf 'hello' > 'old name.txt' && git add . && git commit -qm initial && git mv 'old name.txt' 'new name.txt'", cwd: directory.path)
        let status = await GitService.status(at: directory.path)
        XCTAssertEqual(status.changes.count, 1)
        XCTAssertEqual(status.changes.first?.path, "new name.txt")
        XCTAssertEqual(status.changes.first?.originalPath, "old name.txt")
        XCTAssertEqual(status.changes.first?.displayPath, "old name.txt → new name.txt")
    }

    @MainActor
    func testCommandRunnerSupportsConcurrentProjects() async {
        let projectA = UUID()
        let projectB = UUID()
        async let first = CommandRunner.run(command: "printf project-a; sleep 0.08; printf done", cwd: "/tmp", projectID: projectA)
        async let second = CommandRunner.run(command: "printf project-b; sleep 0.08; printf done", cwd: "/tmp", projectID: projectB)
        let results = await (first, second)
        XCTAssertEqual(results.0.status, 0)
        XCTAssertEqual(results.1.status, 0)
        XCTAssertTrue(results.0.output.contains("project-adone"))
        XCTAssertTrue(results.1.output.contains("project-bdone"))
        XCTAssertFalse(CommandRunner.hasRunningProcesses(projectID: projectA))
        XCTAssertFalse(CommandRunner.hasRunningProcesses(projectID: projectB))
    }

    @MainActor
    func testGitForceDeletesUnmergedBranch() async throws {
        let directory = workspaceRoot.appendingPathComponent(".git-workbench-force-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = await CommandRunner.run(command: "git init -q -b main && git config user.email test@example.com && git config user.name Test && printf base > base.txt && git add . && git commit -qm base && git switch -qc feature && printf branch > branch.txt && git add . && git commit -qm branch && git switch -q main", cwd: directory.path)
        let result = await GitService.deleteBranch("feature", force: true, at: directory.path)
        XCTAssertEqual(result.status, 0)
        let branches = await GitService.branches(at: directory.path)
        XCTAssertFalse(branches.contains("feature"))
    }

    @MainActor
    func testCommandRunnerStopsOneTaskWithoutLeakingProcess() async {
        let projectID = UUID()
        let taskID = UUID()
        let running = Task { await CommandRunner.run(command: "sleep 2", cwd: "/tmp", projectID: projectID, taskID: taskID) }
        try? await Task.sleep(nanoseconds: 120_000_000)
        CommandRunner.stop(taskID: taskID)
        let result = await running.value
        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(CommandRunner.hasRunningProcesses(projectID: projectID))
    }
}
