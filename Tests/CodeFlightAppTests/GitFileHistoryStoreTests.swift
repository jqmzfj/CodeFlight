import XCTest
@testable import CodeFlightApp

@MainActor
final class GitFileHistoryStoreTests: XCTestCase {
    private func fixture() async throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".file-history-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && for n in {1..53}; do printf '%s\\n' $n >> old.swift; git add . && git commit -qm change-$n || exit; done && git mv old.swift current.swift && git commit -qm renamed", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        return root
    }

    func testFilterDoesNotSelectOrRestoreHiddenRevisionAndReturnIsExplicit() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitFileHistoryStore()
        await store.refresh(.init(path: root.path, file: "current.swift"))
        XCTAssertEqual(store.entries.count, 50)
        XCTAssertNil(store.selection, "Loading must not open an unsolicited diff")
        store.selectVisibleCommit()
        let tip = try XCTUnwrap(store.selection)
        store.search = "change-53"
        XCTAssertNil(store.selection)
        XCTAssertNil(store.selected)
        XCTAssertEqual(store.visible.count, 1)
        store.selectVisibleCommit()
        let second = try XCTUnwrap(store.selection)
        XCTAssertNotEqual(second, tip)
        XCTAssertEqual(store.selected?.path, "old.swift")
        for query in ["OLD.SWIFT", "Test", String(second.prefix(12)).uppercased()] {
            store.search = query
            XCTAssertEqual(store.selection, second)
            store.selectVisibleCommit()
            XCTAssertEqual(store.selection, second)
        }
        store.search = "no-match"
        store.selectVisibleCommit()
        XCTAssertNil(store.selected)
        store.search = ""
        XCTAssertNil(store.selection)
        XCTAssertEqual(store.entries.count, 50, "Filtering must not load additional pages")
    }

    func testUnchangedRefreshRetainsPagesAndFrozenPagingSurvivesNewHead() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitFileHistoryStore(), context = GitFileHistoryContext(path: root.path, file: "current.swift")
        await store.refresh(context)
        let hashes = store.entries.map(\.id)
        let update = await CommandRunner.run(command: "printf latest >> current.swift && git add . && git commit -qm latest", cwd: root.path)
        XCTAssertEqual(update.status, 0, update.output)
        await store.loadMore()
        XCTAssertEqual(store.entries.count, 54)
        XCTAssertEqual(Array(store.entries.prefix(50).map(\.id)), hashes)
        XCTAssertEqual(store.entries.last?.path, "old.swift")
        XCTAssertFalse(store.hasMore)
        store.selection = store.entries.last?.id
        await store.refresh(context)
        XCTAssertEqual(store.entries.first?.commit.subject, "latest")
        XCTAssertEqual(store.entries.count, 50, "New HEAD must replace the page snapshot")
        XCTAssertNil(store.selection)
        await store.loadMore()
        store.selection = store.entries.last?.id
        store.search = "old.swift"
        let loaded = store.entries.map(\.id), selected = store.selection
        await store.refresh(context)
        XCTAssertEqual(store.entries.map(\.id), loaded)
        XCTAssertEqual(store.selection, selected)
        XCTAssertEqual(store.search, "old.swift")
    }

    func testRefreshUsesLiveSelectionAndDoesNotRestoreClearedSelection() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitFileHistoryStore(), context = GitFileHistoryContext(path: root.path, file: "current.swift")
        await store.refresh(context)
        let tip = try XCTUnwrap(store.entries.first?.id), second = store.entries[1].id
        store.selection = tip
        _ = await CommandRunner.run(command: "printf latest >> current.swift && git add . && git commit -qm latest", cwd: root.path)
        let refresh = Task { await store.refresh(context) }
        for _ in 0..<1000 { if store.loading { break }; await Task.yield() }
        XCTAssertTrue(store.loading)
        store.selection = second
        await refresh.value
        XCTAssertEqual(store.selection, second)
        let another = Task { await store.refresh(context) }
        for _ in 0..<1000 { if store.loading { break }; await Task.yield() }
        XCTAssertTrue(store.loading)
        store.search = "no-match"; store.search = ""
        await another.value
        XCTAssertNil(store.selection)
    }

    func testSupersededContextCancellationAndReadFailureKeepStateCoherent() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = GitFileHistoryStore(), context = GitFileHistoryContext(path: root.path, file: "current.swift")
        let first = Task { await store.refresh(context) }
        for _ in 0..<1000 { if store.loading { break }; await Task.yield() }
        store.cancel()
        await store.refresh(.init(path: root.path, file: "untracked.swift"))
        await first.value
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.selection)
        XCTAssertFalse(store.loading)
        await store.refresh(context)
        store.selectVisibleCommit()
        let hashes = store.entries.map(\.id), selection = store.selection
        let cancelled = Task { await store.refresh(context) }; cancelled.cancel(); await cancelled.value
        XCTAssertEqual(store.entries.map(\.id), hashes)
        XCTAssertEqual(store.selection, selection)
        try Data("broken\n".utf8).write(to: root.appendingPathComponent(".git/refs/heads/main"))
        await store.refresh(context)
        XCTAssertNotNil(store.failure)
        XCTAssertTrue(store.retryRefresh)
        XCTAssertFalse(store.loading)
        XCTAssertEqual(store.entries.map(\.id), hashes, "Read errors must preserve the review context")
        XCTAssertEqual(store.selection, selection)
    }
}
