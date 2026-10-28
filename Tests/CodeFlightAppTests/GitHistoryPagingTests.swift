import XCTest
@testable import CodeFlightApp

final class GitHistoryPagingTests: XCTestCase {
    @MainActor private func fixture(count: Int = 55) async throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".git-history-paging-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && for n in {1..\(count)}; do git commit -qm \"commit-$n\" --allow-empty || exit; done", cwd: root.path)
        XCTAssertEqual(result.status, 0, result.output)
        return root
    }

    @MainActor func testPagesRetainGraphMetadataAndHaveNoMissingOrDuplicateRecords() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = await GitService.historyPage(at: root.path)
        XCTAssertNil(first.error); XCTAssertEqual(first.commits.count, 50); XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.commits.first?.subject, "commit-55")
        XCTAssertTrue(first.commits.first?.refs.contains("HEAD -> main") == true)
        XCTAssertEqual(first.commits.first?.parents.count, 1)
        let second = await GitService.historyPage(at: root.path, skip: 50, expectedRevision: first.revision)
        XCTAssertNil(second.error); XCTAssertEqual(second.commits.count, 5); XCTAssertFalse(second.hasMore)
        XCTAssertEqual(first.revision, second.revision)
        let records = first.commits + second.commits
        let expected = await CommandRunner.run(command: "git rev-list HEAD", cwd: root.path)
        XCTAssertEqual(Set(records.map(\.hash)).count, 55)
        XCTAssertEqual(records.map(\.hash), expected.output.split(whereSeparator: \.isNewline).map(String.init))
        let negative = await GitService.historyPage(at: root.path, skip: -5)
        XCTAssertEqual(negative.commits.first?.hash, first.commits.first?.hash)
    }

    @MainActor func testHeadOrRefsChangingRequiresRefreshWithoutReturningAMixedPage() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = await GitService.historyPage(at: root.path)
        _ = await CommandRunner.run(command: "git commit -qm new --allow-empty", cwd: root.path)
        let stale = await GitService.historyPage(at: root.path, skip: 50, expectedRevision: first.revision)
        XCTAssertNotNil(stale.error); XCTAssertTrue(stale.requiresRefresh); XCTAssertTrue(stale.commits.isEmpty)
        let fresh = await GitService.historyPage(at: root.path)
        XCTAssertNil(fresh.error); XCTAssertEqual(fresh.commits.first?.subject, "new")
        _ = await CommandRunner.run(command: "git branch feature HEAD~2", cwd: root.path)
        let changedRefs = await GitService.historyPage(at: root.path, skip: 50, allBranches: true, expectedRevision: fresh.revision)
        XCTAssertTrue(changedRefs.requiresRefresh); XCTAssertTrue(changedRefs.commits.isEmpty)
        let all = await GitService.historyPage(at: root.path, allBranches: true)
        XCTAssertNil(all.error)
        _ = await CommandRunner.run(command: "git tag -a -m tag v1 HEAD~4", cwd: root.path)
        let tagged = await GitService.historyPage(at: root.path, skip: 50, allBranches: true, expectedRevision: all.revision)
        XCTAssertTrue(tagged.requiresRefresh)
    }

    @MainActor func testUnbornDetachedAndUnrelatedBranches() async throws {
        let root = try await fixture(count: 1); defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git switch -q --orphan other && git commit -qm unrelated --allow-empty", cwd: root.path)
        let current = await GitService.historyPage(at: root.path)
        XCTAssertEqual(current.commits.map(\.subject), ["unrelated"])
        let all = await GitService.historyPage(at: root.path, allBranches: true)
        XCTAssertEqual(Set(all.commits.map(\.subject)), ["commit-1", "unrelated"])
        _ = await CommandRunner.run(command: "git switch -q --detach main && git init -q empty", cwd: root.path)
        let detached = await GitService.historyPage(at: root.path)
        XCTAssertNil(detached.error); XCTAssertEqual(detached.commits.map(\.subject), ["commit-1"])
        for scope in [false, true] {
            let empty = await GitService.historyPage(at: root.appendingPathComponent("empty").path, allBranches: scope)
            XCTAssertNil(empty.error); XCTAssertTrue(empty.commits.isEmpty); XCTAssertFalse(empty.hasMore)
        }
    }

    @MainActor func testInvalidRepositoryAndBrokenRefReportErrorsRatherThanEmptyHistory() async throws {
        let root = try await fixture(count: 1); defer { try? FileManager.default.removeItem(at: root) }
        // Use a separate non-repository sibling; a child inherits its parent's Git root.
        let missing = root.deletingLastPathComponent().appendingPathComponent(".missing-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: missing) }
        let invalid = await GitService.historyPage(at: missing.path)
        XCTAssertNotNil(invalid.error); XCTAssertTrue(invalid.commits.isEmpty)
        try Data("not-a-hash\n".utf8).write(to: root.appendingPathComponent(".git/refs/heads/main"))
        let broken = await GitService.historyPage(at: root.path)
        XCTAssertNotNil(broken.error); XCTAssertTrue(broken.commits.isEmpty)
    }
    @MainActor func testReferenceNavigationScopesAndPagingNeverCheckoutOrMixScopes() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "git branch feature HEAD~2 && git update-ref refs/remotes/origin/feature feature && git tag -a -m release v1 HEAD~4 && echo dirty > untracked.txt", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        let before = await CommandRunner.run(command: "git symbolic-ref HEAD && git status --porcelain && git rev-parse HEAD", cwd: root.path)
        let local = await GitService.historyPage(at: root.path, reference: "refs/heads/feature")
        XCTAssertNil(local.error); XCTAssertEqual(local.commits.first?.subject, "commit-53")
        XCTAssertEqual(local.commits.count, 50); XCTAssertTrue(local.hasMore)
        let next = await GitService.historyPage(at: root.path, skip: 50, expectedRevision: local.revision, reference: "refs/heads/feature")
        XCTAssertNil(next.error); XCTAssertEqual(next.commits.count, 3); XCTAssertFalse(next.hasMore)
        XCTAssertEqual(Set((local.commits + next.commits).map(\.hash)).count, 53)
        let remote = await GitService.historyPage(at: root.path, reference: "refs/remotes/origin/feature")
        XCTAssertNil(remote.error); XCTAssertEqual(remote.commits.map(\.hash), local.commits.map(\.hash))
        let tag = await GitService.historyPage(at: root.path, reference: "refs/tags/v1")
        XCTAssertNil(tag.error); XCTAssertEqual(tag.commits.first?.subject, "commit-51")
        let mixed = await GitService.historyPage(at: root.path, skip: 50, expectedRevision: local.revision, reference: "refs/tags/v1")
        XCTAssertTrue(mixed.requiresRefresh); XCTAssertTrue(mixed.commits.isEmpty)
        for invalid in ["--all", "refs/heads/missing", "refs/heads/feature~1", "refs/heads/a\nmain", "refs/tags/"] {
            let page = await GitService.historyPage(at: root.path, reference: invalid)
            XCTAssertNotNil(page.error, invalid); XCTAssertTrue(page.commits.isEmpty)
        }
        let after = await CommandRunner.run(command: "git symbolic-ref HEAD && git status --porcelain && git rev-parse HEAD", cwd: root.path)
        XCTAssertEqual(before.output, after.output)
    }

}
