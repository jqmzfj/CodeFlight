import XCTest
@testable import CodeFlightApp

final class GitBlameTests: XCTestCase {
    @MainActor private func fixture() async throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".git-blame-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name First && git config user.email test@example.com", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        return root
    }

    @MainActor func testAuthorsRenamesAndLocalLinesPreserveIndexAndWorktree() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = "old [1].swift", file = "新\t\"name.swift"
        try "let first = 1\nlet second = 2\nlet third = 3\n".write(to: root.appendingPathComponent(old), atomically: true, encoding: .utf8)
        let first = await CommandRunner.run(command: "git add . && git commit -qm first && git rev-parse HEAD", cwd: root.path)
        XCTAssertEqual(first.status, 0, first.output)
        let hash = first.output.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await CommandRunner.run(command: "git mv -- \(Shell.quote(old)) \(Shell.quote(file)) && git commit -qm rename", cwd: root.path)
        try "let first = 1\nlet second = 20\nlet third = 3\n".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        _ = await CommandRunner.run(command: "git add . && git -c user.name=Second commit -qm second", cwd: root.path)
        try "let first = 1\nlet second = 20\nlet third = 30\n".write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        _ = await CommandRunner.run(command: "git add .", cwd: root.path)
        let content = "let first = 1\nlet second = 20\nlet third = 300\n\n"
        try content.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        let before = await CommandRunner.run(command: "git diff --cached --binary && git diff --binary", cwd: root.path)
        let result = await GitService.blame(file, at: root.path)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.lines.count, 4)
        XCTAssertEqual(result.lines.first?.hash, hash)
        XCTAssertEqual(result.lines.first?.path, old)
        XCTAssertEqual(result.lines.first?.author, "First")
        XCTAssertEqual(result.lines[1].author, "Second")
        XCTAssertEqual(result.lines[1].path, file)
        XCTAssertEqual(result.lines[1].content, "let second = 20")
        XCTAssertTrue(result.lines[2].uncommitted)
        XCTAssertTrue(result.lines[3].uncommitted)
        XCTAssertEqual(result.lines[3].content, "")
        XCTAssertEqual(result.lines.map(\.line), [1, 2, 3, 4])
        let after = await CommandRunner.run(command: "git diff --cached --binary && git diff --binary", cwd: root.path)
        XCTAssertEqual(before.output, after.output)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(file)), content)
    }

    @MainActor func testUntrackedUnbornAndEmptyFilesHaveClearResults() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "untracked".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let unborn = await GitService.blame("new.txt", at: root.path)
        XCTAssertNotNil(unborn.error)
        _ = await CommandRunner.run(command: "git add . && git commit -qm initial", cwd: root.path)
        try Data().write(to: root.appendingPathComponent("empty.txt"))
        _ = await CommandRunner.run(command: "git add . && git commit -qm empty", cwd: root.path)
        let empty = await GitService.blame("empty.txt", at: root.path)
        XCTAssertNil(empty.error)
        XCTAssertTrue(empty.lines.isEmpty)
        try "new".write(to: root.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        let untracked = await GitService.blame("untracked.txt", at: root.path)
        XCTAssertNotNil(untracked.error)
    }

    @MainActor func testLimitsBinarySymlinksAndTraversalAreRejected() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary"))
        try Data([0xff]).write(to: root.appendingPathComponent("nonutf8"))
        try Data(repeating: 65, count: 1024 * 1024 + 1).write(to: root.appendingPathComponent("large"))
        try String(repeating: "x\n", count: 10_001).write(to: root.appendingPathComponent("lines"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: root.appendingPathComponent("binary").path)
        for file in ["binary", "nonutf8", "large", "lines", "link", "../outside", "/etc/hosts", "bad\0name", ""] {
            let result = await GitService.blame(file, at: root.path)
            XCTAssertNotNil(result.error, file)
            XCTAssertTrue(result.lines.isEmpty, file)
        }
    }

    func testParserPreservesWhitespaceCRAndQuotedHistoricalPath() {
        let hash = String(repeating: "a", count: 40)
        let result = GitService.parseBlame("\(hash) 5 1 1\nauthor Example\nauthor-time 0\nsummary Initial\nfilename \"old\\t\\042name\\042.swift\"\n\t  value\t\r\n")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.lines.first?.path, "old\t\"name\".swift")
        XCTAssertEqual(result.lines.first?.originalLine, 5)
        XCTAssertEqual(result.lines.first?.content, "  value\t\r")
        XCTAssertEqual(result.lines.first?.date, "1970-01-01")
    }

    func testLineLimitIncludesFinalUnterminatedLine() {
        XCTAssertTrue(GitService.blameTextIsSupported(Data()))
        XCTAssertTrue(GitService.blameTextIsSupported(Data(String(repeating: "x\n", count: 10_000).utf8)))
        XCTAssertTrue(GitService.blameTextIsSupported(Data((String(repeating: "x\n", count: 9_999) + "final").utf8)))
        XCTAssertFalse(GitService.blameTextIsSupported(Data((String(repeating: "x\n", count: 10_000) + "final").utf8)))
    }

    func testMalformedAnnotationsRejectDuplicateGapsAndIncompleteRecords() {
        let hash = String(repeating: "a", count: 40)
        func record(_ number: Int) -> String { "\(hash) 1 \(number) 1\nauthor Example\nauthor-time 0\nsummary Message\nfilename file.swift\n\tlet value = 1\n" }
        for value in [record(1) + record(1), record(1) + record(3), "\(hash) 1 1 1\n" + record(1), record(1) + "\(hash) 2 2 1\n"] {
            let result = GitService.parseBlame(value)
            XCTAssertNotNil(result.error); XCTAssertTrue(result.lines.isEmpty)
        }
    }

    @MainActor func testCancelledReadAndKnownFailuresUseCurrentLanguage() async {
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            return await GitService.blame("file.swift", at: "/does-not-exist", language: .english)
        }
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertEqual(result.error, "Read cancelled."); XCTAssertTrue(result.lines.isEmpty)
        let zh = await GitService.blame("../outside", at: "/does-not-exist", language: .chinese)
        let en = await GitService.blame("../outside", at: "/does-not-exist", language: .english)
        XCTAssertEqual(zh.error, "请选择仓库内的普通文本文件。")
        XCTAssertEqual(en.error, "Select a regular text file inside the repository.")
    }

}
