import XCTest
@testable import CodeFlightApp

final class GitBranchFormTests: XCTestCase {
    @MainActor
    private func fixture() async throws -> URL {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".git-branch-form-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = await CommandRunner.run(command: "git init -q -b main && git -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm initial", cwd: root.path)
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: root)
            throw NSError(domain: "BranchFixture", code: Int(result.status))
        }
        return root
    }

    @MainActor
    func testCreateFailureCanRetryAndRenameReportsFailureWithoutGlobalError() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkbenchModel(restoringSession: false)
        let project = Project(name: "test", path: root.path)
        model.projects = [project]; model.selectedProjectID = project.id
        let failure: CommandResult = await withCheckedContinuation { continuation in
            model.createBranch("main", checkout: false) { continuation.resume(returning: $0) }
        }
        XCTAssertNotEqual(failure.status, 0)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isGitBusy)
        let retry: CommandResult = await withCheckedContinuation { continuation in
            model.createBranch("feature/retry", checkout: false) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(retry.status, 0, retry.output)
        XCTAssertEqual(model.gitBranch, "main")
        XCTAssertTrue(model.gitBranches.contains("feature/retry"))
        let renameFailure: CommandResult = await withCheckedContinuation { continuation in
            model.renameBranch("main", to: "feature/retry") { continuation.resume(returning: $0) }
        }
        XCTAssertNotEqual(renameFailure.status, 0)
        XCTAssertNil(model.errorMessage)
        let rename: CommandResult = await withCheckedContinuation { continuation in
            model.renameBranch("main", to: "renamed") { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(rename.status, 0, rename.output)
        XCTAssertEqual(model.gitBranch, "renamed")
    }

    @MainActor
    func testBranchNamesCannotBeInterpretedAsCommandOptions() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for invalid in ["", "--delete", "-M", "bad name", "feature..bad", "refs/heads/bad.lock"] {
            let create = await GitService.createBranch(invalid, checkout: false, at: root.path)
            XCTAssertNotEqual(create.status, 0, invalid)
            let rename = await GitService.renameBranch("main", to: invalid, at: root.path)
            XCTAssertNotEqual(rename.status, 0, invalid)
        }
        let branches = await GitService.branches(at: root.path)
        XCTAssertEqual(branches, ["main"])
    }

    @MainActor
    func testMissingProjectSettlesCompletionInsteadOfLeavingFormBusy() {
        let model = WorkbenchModel(restoringSession: false)
        var results: [CommandResult] = []
        model.createBranch("new") { results.append($0) }
        model.renameBranch("main", to: "new") { results.append($0) }
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.status != 0 })
        XCTAssertFalse(model.isGitBusy)
    }

    @MainActor
    func testAdvancedFailureCanRetryWithoutLosingWorkingTree() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("keep.txt")
        try Data("uncommitted\n".utf8).write(to: file)
        let model = WorkbenchModel(restoringSession: false)
        let project = Project(name: "test", path: root.path)
        model.projects = [project]; model.selectedProjectID = project.id
        let failure: CommandResult = await withCheckedContinuation { continuation in
            model.gitAdvanced(.resetSoft, value: "not-a-real-reference") { continuation.resume(returning: $0) }
        }
        XCTAssertNotEqual(failure.status, 0)
        XCTAssertNil(model.errorMessage)
        let retry: CommandResult = await withCheckedContinuation { continuation in
            model.gitAdvanced(.resetSoft, value: "HEAD") { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(retry.status, 0, retry.output)
        XCTAssertEqual(try String(contentsOf: file), "uncommitted\n")
    }
}
