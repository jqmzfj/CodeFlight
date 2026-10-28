import XCTest
@testable import CodeFlightApp

final class GitFileHistorySnapshotTests: XCTestCase {
    @MainActor private func fixture() async throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".git-file-snapshot-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf 'base\\n' > 'old [1].txt' && git add . && git commit -qm first && printf 'one\\n' >> 'old [1].txt' && git add . && git commit -qm second && git mv 'old [1].txt' 'current [1].txt' && git commit -qm renamed && printf 'two\\n' >> 'current [1].txt' && git add . && git commit -qm fourth", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        return root
    }

    @MainActor func testSnapshotPaginationAcrossRenameSurvivesNewCommitAndBranchSwitch() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = await GitService.fileHistory("current [1].txt", at: root.path, limit: 2)
        XCTAssertNil(first.error); XCTAssertEqual(first.entries.map { $0.commit.subject }, ["fourth", "renamed"])
        let snapshot = try XCTUnwrap(first.snapshot)
        _ = await CommandRunner.run(command: "printf 'latest\\n' >> 'current [1].txt' && git add . && git commit -qm latest", cwd: root.path)
        let second = await GitService.fileHistory("current [1].txt", at: root.path, skip: 2, limit: 2, snapshot: snapshot)
        XCTAssertNil(second.error); XCTAssertEqual(second.snapshot, snapshot)
        XCTAssertEqual(second.entries.map { $0.commit.subject }, ["second", "first"])
        XCTAssertEqual(second.entries.map(\.path), ["old [1].txt", "old [1].txt"])
        XCTAssertFalse(second.hasMore)
        let allHashes = first.entries.map(\.id) + second.entries.map(\.id)
        XCTAssertEqual(Set(allHashes).count, 4)
        _ = await CommandRunner.run(command: "git switch -qc other HEAD~3", cwd: root.path)
        let switched = await GitService.fileHistory("current [1].txt", at: root.path, skip: 2, limit: 2, snapshot: snapshot)
        XCTAssertNil(switched.error); XCTAssertEqual(switched.entries.map(\.id), second.entries.map(\.id))
        let oldDiff = await GitService.commitDiff(second.entries.last!.id, file: second.entries.last!.path, at: root.path)
        XCTAssertTrue(oldDiff.contains("+base"), oldDiff)
    }

    @MainActor func testFreshRequestReadsLatestHeadAndPreservesDirtyIndexAndWorktree() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let previous = await GitService.fileHistory("current [1].txt", at: root.path, limit: 1)
        _ = await CommandRunner.run(command: "printf 'new\\n' >> 'current [1].txt' && git add . && git commit -qm new && printf staged > extra && git add extra && printf dirty >> extra && printf keep > untracked", cwd: root.path)
        let before = await CommandRunner.run(command: "git rev-parse HEAD && git status --porcelain && git diff --binary && git diff --cached --binary", cwd: root.path)
        let fresh = await GitService.fileHistory("current [1].txt", at: root.path, limit: 1)
        XCTAssertNil(fresh.error); XCTAssertEqual(fresh.entries.first?.commit.subject, "new")
        XCTAssertNotEqual(previous.snapshot, fresh.snapshot)
        let frozen = await GitService.fileHistory("current [1].txt", at: root.path, limit: 1, snapshot: previous.snapshot)
        XCTAssertNil(frozen.error); XCTAssertEqual(frozen.entries.first?.commit.subject, "fourth")
        let after = await CommandRunner.run(command: "git rev-parse HEAD && git status --porcelain && git diff --binary && git diff --cached --binary", cwd: root.path)
        XCTAssertEqual(before.output, after.output)
    }

    @MainActor func testUnavailableSnapshotsAndCorruptHeadAreNotEmptyHistory() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for snapshot in ["HEAD", "--help", "HEAD; touch injected", String(repeating: "0", count: 40)] {
            let invalid = await GitService.fileHistory("current [1].txt", at: root.path, snapshot: snapshot)
            XCTAssertNotNil(invalid.error); XCTAssertTrue(invalid.entries.isEmpty)
        }
        let valid = await GitService.fileHistory("current [1].txt", at: root.path, limit: 1)
        try Data("broken\n".utf8).write(to: root.appendingPathComponent(".git/refs/heads/main"))
        let broken = await GitService.fileHistory("current [1].txt", at: root.path)
        XCTAssertNotNil(broken.error)
        // A known commit remains readable even when HEAD's ref is corrupt.
        let frozen = await GitService.fileHistory("current [1].txt", at: root.path, limit: 1, snapshot: valid.snapshot)
        XCTAssertNil(frozen.error); XCTAssertEqual(frozen.entries.first?.id, valid.entries.first?.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path))
    }
}
