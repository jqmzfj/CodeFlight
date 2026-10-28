import XCTest
@testable import CodeFlightApp

final class GitIgnoreTests: XCTestCase {
    @MainActor
    private func fixture() async throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".git-ignore-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf tracked > tracked.txt && git add . && git commit -qm initial", cwd: root.path)
        guard setup.status == 0 else { try? FileManager.default.removeItem(at: root); throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: setup.output]) }
        return root
    }

    @MainActor
    func testLiteralRuleOnlyIgnoresChosenSpecialPathAndLeavesFilesOnDisk() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let filename = "folder/#cache [1]*?!.log "
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try "keep".write(to: root.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        try "other".write(to: root.appendingPathComponent("folder/#cache 1xxxx.log"), atomically: true, encoding: .utf8)
        let result = await GitService.ignoreUntrackedFile(filename, at: root.path)
        XCTAssertEqual(result.status, 0, result.output)
        let others = await CommandRunner.run(command: "git ls-files --others --exclude-standard -z", cwd: root.path)
        XCTAssertFalse(others.output.components(separatedBy: "\0").contains(filename))
        XCTAssertTrue(others.output.components(separatedBy: "\0").contains("folder/#cache 1xxxx.log"))
        XCTAssertTrue(others.output.components(separatedBy: "\0").contains(".gitignore"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(filename)), "keep")
        let index = await CommandRunner.run(command: "git diff --cached --name-only", cwd: root.path)
        XCTAssertTrue(index.output.isEmpty)
    }

    @MainActor
    func testAppendPreservesCRLFExistingChangesPermissionsAndIndex() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let ignore = root.appendingPathComponent(".gitignore")
        try "# staged\r\n*.tmp\r\n".write(to: ignore, atomically: true, encoding: .utf8)
        _ = await CommandRunner.run(command: "git add .gitignore", cwd: root.path)
        let stagedBefore = await CommandRunner.run(command: "git show :.gitignore", cwd: root.path)
        try "# working\r\n*.tmp".write(to: ignore, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: ignore.path)
        try "keep".write(to: root.appendingPathComponent("local.log"), atomically: true, encoding: .utf8)
        let result = await GitService.ignoreUntrackedFile("local.log", at: root.path)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(try String(contentsOf: ignore), "# working\r\n*.tmp\r\n/local.log\r\n")
        let index = await CommandRunner.run(command: "git show :.gitignore", cwd: root.path)
        XCTAssertEqual(index.output, stagedBefore.output)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: ignore.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }

    @MainActor
    func testNearestIgnoreOverridesNestedNegationWithoutChangingRootRules() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try "*.log\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "!keep.log\n".write(to: root.appendingPathComponent("nested/.gitignore"), atomically: true, encoding: .utf8)
        try "keep".write(to: root.appendingPathComponent("nested/keep.log"), atomically: true, encoding: .utf8)
        let result = await GitService.ignoreUntrackedFile("nested/keep.log", at: root.appendingPathComponent("nested").path)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".gitignore")), "*.log\n")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("nested/.gitignore")), "!keep.log\n/keep.log\n")
        let listed = await CommandRunner.run(command: "git ls-files --others --exclude-standard -z", cwd: root.path)
        XCTAssertFalse(listed.output.components(separatedBy: "\0").contains("nested/keep.log"))
    }

    @MainActor
    func testTrackedStagedMissingAndInvalidPathsCannotChangeIgnoreFile() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "new".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        _ = await CommandRunner.run(command: "git add new.txt", cwd: root.path)
        for path in ["tracked.txt", "new.txt", "missing", ".gitignore", "../outside", "/absolute", "folder/../tracked.txt", "bad\nname", "bad\0name", ".git/config"] {
            let result = await GitService.ignoreUntrackedFile(path, at: root.path)
            XCTAssertNotEqual(result.status, 0, path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".gitignore").path))
        }
    }

    @MainActor
    func testSymlinkOversizedAndNonUTF8IgnoreFilesArePreserved() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "keep".write(to: root.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        let ignore = root.appendingPathComponent(".gitignore")
        try FileManager.default.createSymbolicLink(atPath: ignore.path, withDestinationPath: root.appendingPathComponent("tracked.txt").path)
        let symlink = await GitService.ignoreUntrackedFile("local.txt", at: root.path)
        XCTAssertNotEqual(symlink.status, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("tracked.txt")), "tracked")
        try FileManager.default.removeItem(at: ignore)
        for bytes in [Data(repeating: 35, count: 1024 * 1024 + 1), Data([0xff, 0xfe, 0, 0])] {
            try bytes.write(to: ignore)
            let result = await GitService.ignoreUntrackedFile("local.txt", at: root.path)
            XCTAssertNotEqual(result.status, 0)
            XCTAssertEqual(try Data(contentsOf: ignore), bytes)
        }
    }

    @MainActor
    func testConflictedIgnoreFileRemainsUnchanged() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "printf '# base\\n' > .gitignore && git add .gitignore && git commit -qm base && git switch -qc topic && printf '# topic\\n' > .gitignore && git commit -qam topic && git switch -q main && printf '# main\\n' > .gitignore && git commit -qam main && git merge topic", cwd: root.path)
        try "keep".write(to: root.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: root.appendingPathComponent(".gitignore"))
        let result = await GitService.ignoreUntrackedFile("local.txt", at: root.path)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".gitignore")), before)
    }
}
