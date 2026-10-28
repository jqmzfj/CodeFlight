import XCTest
@testable import CodeFlightApp

@MainActor
final class GitHistoryStoreTests: XCTestCase {
    private func fixture() async throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".history-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && for n in {1..55}; do git commit -qm commit-$n --allow-empty || exit; done && git branch feature HEAD~3", cwd: root.path)
        XCTAssertEqual(result.status, 0, result.output)
        return root
    }

    func testUnchangedRefreshRetainsOlderPagesSelectionAndGraph() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHistoryStore(), context = GitHistoryContext(path: root.path, scope: "HEAD")
        await store.refresh(context)
        await store.loadMore()
        let hashes = store.commits.map(\.hash)
        store.selectedHash = hashes.last
        await store.refresh(context)
        XCTAssertEqual(store.commits.map(\.hash), hashes)
        XCTAssertEqual(store.selectedHash, hashes.last)
        XCTAssertEqual(store.graph.count, 55)
        XCTAssertTrue(store.reachedEnd)
        XCTAssertFalse(store.loading)
        XCTAssertNil(store.failure)
    }

    func testFilteringKeepsVisibleSelectionAndClearsHiddenInspectorWithoutRestoringIt() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHistoryStore()
        await store.refresh(GitHistoryContext(path: root.path, scope: "HEAD"))
        let tip = try XCTUnwrap(store.commits.first)
        store.selectedHash = tip.hash
        for query in ["COMMIT-55", String(tip.hash.prefix(12)).uppercased(), "Test", "main"] {
            store.search = query
            XCTAssertTrue(store.visibleCommits.contains { $0.hash == tip.hash })
            XCTAssertEqual(store.selectedHash, tip.hash)
        }
        store.search = "commit-54"
        XCTAssertNil(store.selectedHash, "A filtered-out commit must not remain in the inspector")
        store.selectVisibleCommit()
        let second = try XCTUnwrap(store.selectedHash)
        XCTAssertEqual(store.visibleCommits.first?.hash, second)
        XCTAssertEqual(store.visibleCommits.first?.subject, "commit-54")
        store.search = "commit-"
        store.selectVisibleCommit()
        XCTAssertEqual(store.selectedHash, second, "Return must keep an already visible selected result")
        store.search = "no-match"
        store.selectVisibleCommit()
        XCTAssertTrue(store.visibleCommits.isEmpty)
        XCTAssertNil(store.selectedHash)
        store.search = ""
        XCTAssertNil(store.selectedHash, "Clearing search must not resurrect a hidden selection")
        XCTAssertEqual(store.commits.count, 50, "Filtering must not eagerly fetch older pages")
    }

    func testRefreshingRemovedMatchingReferenceClearsSelectionAndPagingKeepsFilter() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let context = GitHistoryContext(path: root.path, scope: "HEAD")
        let store = GitHistoryStore()
        _ = await CommandRunner.run(command: "git tag focus-marker", cwd: root.path)
        await store.refresh(context)
        store.search = "focus-marker"
        store.selectVisibleCommit()
        XCTAssertNotNil(store.selectedHash)
        _ = await CommandRunner.run(command: "git tag -d focus-marker", cwd: root.path)
        await store.refresh(context)
        XCTAssertNil(store.selectedHash)
        XCTAssertTrue(store.visibleCommits.isEmpty)
        store.search = "commit-1"
        await store.loadMore()
        XCTAssertTrue(store.visibleCommits.contains { $0.subject == "commit-1" })
        XCTAssertTrue(store.visibleCommits.allSatisfy { $0.subject.contains("commit-1") })
        store.selectVisibleCommit()
        XCTAssertNotNil(store.selectedHash)
        await store.refresh(context)
        XCTAssertNotNil(store.selectedHash)
    }

    func testChangedSnapshotRefreshKeepsSelectionEditsMadeDuringRead() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHistoryStore(), context = GitHistoryContext(path: root.path, scope: "HEAD")
        await store.refresh(context)
        let tip = try XCTUnwrap(store.commits.first?.hash)
        let second = try XCTUnwrap(store.commits.dropFirst().first?.hash)
        store.selectedHash = tip
        let firstMutation = await CommandRunner.run(command: "git commit -qm snapshot-one --allow-empty", cwd: root.path)
        XCTAssertEqual(firstMutation.status, 0, firstMutation.output)
        let firstRefresh = Task { await store.refresh(context) }
        for _ in 0..<1000 {
            if store.loading { break }
            await Task.yield()
        }
        XCTAssertTrue(store.loading, "The selection must change while the actual repository read is pending")
        store.selectedHash = second
        await firstRefresh.value
        XCTAssertEqual(store.selectedHash, second, "Refresh must not restore the selection captured before the read")

        store.selectedHash = tip
        let secondMutation = await CommandRunner.run(command: "git commit -qm snapshot-two --allow-empty", cwd: root.path)
        XCTAssertEqual(secondMutation.status, 0, secondMutation.output)
        let secondRefresh = Task { await store.refresh(context) }
        for _ in 0..<1000 {
            if store.loading { break }
            await Task.yield()
        }
        XCTAssertTrue(store.loading)
        store.search = "no-match"
        store.search = ""
        XCTAssertNil(store.selectedHash)
        await secondRefresh.value
        XCTAssertNil(store.selectedHash, "Clearing a filtered-out selection during refresh must remain cleared")
    }

    func testChangedSnapshotAndScopeDoNotMixPagesOrKeepForeignSelection() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHistoryStore(), context = GitHistoryContext(path: root.path, scope: "HEAD")
        await store.refresh(context)
        let tip = try XCTUnwrap(store.commits.first?.hash)
        store.selectedHash = tip
        _ = await CommandRunner.run(command: "git commit -qm new-tip --allow-empty", cwd: root.path)
        await store.refresh(context)
        XCTAssertEqual(store.commits.first?.subject, "new-tip")
        XCTAssertEqual(store.selectedHash, tip)
        await store.loadMore()
        XCTAssertEqual(store.commits.count, 56)
        XCTAssertEqual(Set(store.commits.map(\.hash)).count, 56)
        await store.refresh(GitHistoryContext(path: root.path, scope: "refs/heads/feature"))
        XCTAssertEqual(store.commits.first?.subject, "commit-52")
        XCTAssertNil(store.selectedHash)
        XCTAssertFalse(store.commits.contains { $0.hash == tip })
    }

    func testStalePagingRequiresRefreshAndDoesNotAppendChangedHistory() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHistoryStore(), context = GitHistoryContext(path: root.path, scope: "HEAD")
        await store.refresh(context)
        let hashes = store.commits.map(\.hash)
        _ = await CommandRunner.run(command: "git tag v1 HEAD~4", cwd: root.path)
        await store.loadMore()
        XCTAssertTrue(store.requiresRefresh)
        XCTAssertNotNil(store.failure)
        XCTAssertEqual(store.commits.map(\.hash), hashes)
        await store.refresh(context)
        XCTAssertFalse(store.requiresRefresh)
        XCTAssertNil(store.failure)
        XCTAssertEqual(store.commits.count, 50)
    }

    func testCancelledAndSupersededLoadsCannotReplaceActiveScope() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitHistoryStore()
        let first = Task { await store.refresh(GitHistoryContext(path: root.path, scope: "HEAD")) }
        await Task.yield()
        store.cancel()
        await store.refresh(GitHistoryContext(path: root.path, scope: "refs/heads/feature"))
        await first.value
        XCTAssertEqual(store.commits.first?.subject, "commit-52")
        XCTAssertFalse(store.loading)
        let cancelled = Task { await store.refresh(GitHistoryContext(path: root.path, scope: "HEAD")) }
        cancelled.cancel()
        await cancelled.value
        XCTAssertFalse(store.loading)
        XCTAssertEqual(store.commits.first?.subject, "commit-52")
    }
}
