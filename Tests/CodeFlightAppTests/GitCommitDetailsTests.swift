import XCTest
@testable import CodeFlightApp

final class GitCommitDetailsTests: XCTestCase {
    @MainActor private func fixture() async throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".git-commit-details-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        return root
    }

    @MainActor func testRootAndEmptyCommitsWithSpecialPathsPreserveWorkspace() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = ["中文 [1].swift", "tab\tname", "line\nname", "--option"]
        for path in paths { try Data("base".utf8).write(to: root.appendingPathComponent(path)) }
        let initial = await CommandRunner.run(command: "git add --all && git commit -qm '初始说明'", cwd: root.path)
        XCTAssertEqual(initial.status, 0, initial.output)
        _ = await CommandRunner.run(command: "printf staged > staged && git add staged && printf dirty >> staged && printf keep > untracked", cwd: root.path)
        let before = await CommandRunner.run(command: "git rev-parse HEAD && git status --porcelain && git diff --binary && git diff --cached --binary", cwd: root.path)
        let details = await GitService.commitDetails("HEAD", at: root.path)
        XCTAssertNil(details.error); XCTAssertEqual(Set(details.files), Set(paths)); XCTAssertTrue(details.description.contains("初始说明"))
        let after = await CommandRunner.run(command: "git rev-parse HEAD && git status --porcelain && git diff --binary && git diff --cached --binary", cwd: root.path)
        XCTAssertEqual(before.output, after.output)
        _ = await CommandRunner.run(command: "git commit -qm staged && git commit -qm empty --allow-empty", cwd: root.path)
        let empty = await GitService.commitDetails("HEAD", at: root.path)
        XCTAssertNil(empty.error); XCTAssertTrue(empty.files.isEmpty); XCTAssertTrue(empty.description.contains("empty"))
    }

    @MainActor func testMergeUsesFirstParentFileChanges() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "git commit -qm base --allow-empty && git switch -qc side && printf side > side.txt && git add . && git commit -qm side && git switch -q main && printf main > main.txt && git add . && git commit -qm main && git merge -q --no-ff -m merged side", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        let merge = await GitService.commitDetails("HEAD", at: root.path)
        XCTAssertNil(merge.error); XCTAssertEqual(merge.files, ["side.txt"]); XCTAssertTrue(merge.description.contains("merged"))
    }

    @MainActor func testTruncatedDescriptionOrFileListIsAnError() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data(String(repeating: "长说明 ", count: 1000).utf8).write(to: root.appendingPathComponent(".git/message"))
        let setup = await CommandRunner.run(command: "printf content > first.txt && printf content > second.txt && git add . && git commit -q -F .git/message", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        let longMessage = await GitService.commitDetails("HEAD", at: root.path, descriptionLimit: 128)
        XCTAssertNotNil(longMessage.error); XCTAssertTrue(longMessage.files.isEmpty)
        let longFiles = await GitService.commitDetails("HEAD", at: root.path, fileLimit: 1)
        XCTAssertNotNil(longFiles.error); XCTAssertTrue(longFiles.files.isEmpty); XCTAssertFalse(longFiles.description.isEmpty)
        let normal = await GitService.commitDetails("HEAD", at: root.path)
        XCTAssertNil(normal.error); XCTAssertEqual(normal.files, ["first.txt", "second.txt"])
    }

    @MainActor func testInvalidCommitAndMissingObjectReportErrorAndRecover() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git commit -qm initial --allow-empty", cwd: root.path)
        for ref in ["--help", "HEAD; touch injected", String(repeating: "0", count: 40)] {
            let invalid = await GitService.commitDetails(ref, at: root.path)
            XCTAssertNotNil(invalid.error); XCTAssertTrue(invalid.files.isEmpty)
        }
        let hashResult = await CommandRunner.run(command: "git rev-parse HEAD", cwd: root.path)
        let hash = hashResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let object = root.appendingPathComponent(".git/objects/" + hash.prefix(2) + "/" + hash.dropFirst(2))
        let data = try Data(contentsOf: object)
        try FileManager.default.removeItem(at: object)
        let missing = await GitService.commitDetails(hash, at: root.path)
        XCTAssertNotNil(missing.error)
        try data.write(to: object)
        let restored = await GitService.commitDetails(hash, at: root.path)
        XCTAssertNil(restored.error); XCTAssertTrue(restored.description.contains("initial"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path))
    }
}
