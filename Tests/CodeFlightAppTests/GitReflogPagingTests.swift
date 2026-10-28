import XCTest
@testable import CodeFlightApp

final class GitReflogPagingTests: XCTestCase {
    @MainActor private func fixture() async throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".git-reflog-page-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.invalid && printf one > file.txt && git add . && git commit -qm first && printf two > file.txt && git add . && git commit -qm 'second | 中文' && printf three > file.txt && git add . && git commit -qm third", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        return root
    }

    @MainActor func testReflogPagesCoverAllEntriesAndPreserveWorktree() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "printf staged > file.txt && git add file.txt && printf dirty >> file.txt && printf keep > untracked", cwd: root.path)
        let before = await CommandRunner.run(command: "git rev-parse HEAD && git status --porcelain && git diff --binary && git diff --cached --binary", cwd: root.path)
        let all = await GitService.reflogPage(at: root.path)
        XCTAssertNil(all.failure); XCTAssertEqual(all.entries.count, 6); XCTAssertFalse(all.hasMore)
        XCTAssertTrue(all.entries.contains { $0.subject.contains("second | 中文") })
        var accumulated: [GitReflogEntry] = []
        for _ in 0..<4 {
            let page = await GitService.reflogPage(at: root.path, skip: accumulated.count, limit: 2, expectedPrefix: accumulated.map(\.id))
            XCTAssertNil(page.failure)
            accumulated.append(contentsOf: page.entries)
            if !page.hasMore { break }
        }
        XCTAssertEqual(accumulated.map(\.id), all.entries.map(\.id))
        XCTAssertEqual(Set(accumulated.map(\.id)).count, 6)
        let after = await CommandRunner.run(command: "git rev-parse HEAD && git status --porcelain && git diff --binary && git diff --cached --binary", cwd: root.path)
        XCTAssertEqual(before.output, after.output)
    }

    @MainActor func testReflogMutationRequiresRefreshInsteadOfMixingPages() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = await GitService.reflogPage(at: root.path, limit: 2)
        XCTAssertNil(first.failure); XCTAssertTrue(first.hasMore)
        _ = await CommandRunner.run(command: "git reset --soft HEAD~1", cwd: root.path)
        let stale = await GitService.reflogPage(at: root.path, skip: 2, limit: 2, expectedPrefix: first.entries.map(\.id))
        XCTAssertNotNil(stale.failure); XCTAssertTrue(stale.requiresRefresh); XCTAssertTrue(stale.entries.isEmpty)
        let refreshed = await GitService.reflogPage(at: root.path)
        XCTAssertNil(refreshed.failure); XCTAssertFalse(refreshed.entries.isEmpty)
        let invalid = await GitService.reflogPage(at: root.path, skip: 2, expectedPrefix: [])
        XCTAssertNotNil(invalid.failure); XCTAssertTrue(invalid.requiresRefresh)
    }

    @MainActor func testEmptyReflogIsDistinctFromReadFailureAndTruncation() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let truncated = await GitService.reflogPage(at: root.path, outputLimit: 32)
        XCTAssertNotNil(truncated.failure); XCTAssertTrue(truncated.entries.isEmpty)
        let invalid = await GitService.reflogPage(at: root.deletingLastPathComponent().path)
        XCTAssertNotNil(invalid.failure); XCTAssertTrue(invalid.entries.isEmpty)
        _ = await CommandRunner.run(command: "git reflog expire --expire=all --all", cwd: root.path)
        let empty = await GitService.reflogPage(at: root.path)
        XCTAssertNil(empty.failure); XCTAssertTrue(empty.entries.isEmpty); XCTAssertFalse(empty.hasMore)
    }

    func testKnownFailuresFollowLanguageAndRawGitDiagnosticsRemainIntact() {
        let zh = GitReflogFailure.changed.message(language: .chinese)
        let en = GitReflogFailure.changed.message(language: .english)
        XCTAssertTrue(zh.contains("操作记录")); XCTAssertFalse(zh.contains("Reflog"))
        XCTAssertTrue(en.contains("Reflog")); XCTAssertFalse(en.contains("操作记录"))
        let raw = "fatal: path / custom diagnostic\n下一行"
        XCTAssertEqual(GitReflogFailure.command(raw).message(language: .chinese), raw)
        XCTAssertEqual(GitReflogFailure.command(raw).message(language: .english), raw)
        XCTAssertFalse(GitReflogFailure.command("").message(language: .chinese).isEmpty)
    }

    func testMalformedReflogNeverProducesPartialSuccess() {
        let hash = String(repeating: "a", count: 40)
        let record = "\(hash)\0HEAD@{0}\0commit: 中文 | message\02026-10-26T10:00:00+08:00\0"
        XCTAssertEqual(GitService.parseReflog(record)?.first?.subject, "commit: 中文 | message")
        XCTAssertEqual(GitService.parseReflog("")?.count, 0)
        for value in [String(record.dropLast()), record + "broken", "bad\0HEAD@{0}\0subject\0date\0", "\(hash)\0\0subject\0date\0"] {
            XCTAssertNil(GitService.parseReflog(value))
        }
    }
}
