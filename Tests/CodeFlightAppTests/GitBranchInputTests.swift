import XCTest
@testable import CodeFlightApp

final class GitBranchInputTests: XCTestCase {
    @MainActor
    private func fixture() async throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".git-branch-input-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && printf base > vanished && git add . && git commit -qm initial", cwd: root.path)
        guard setup.status == 0 else { try? FileManager.default.removeItem(at: root); throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: setup.output]) }
        return root
    }

    @MainActor
    func testMissingBranchDoesNotRestoreSameNamedWorkingFileOrGuessRemote() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git branch vanished && git branch -d vanished && git remote add origin . && git update-ref refs/remotes/origin/vanished HEAD", cwd: root.path)
        try "local edits".write(to: root.appendingPathComponent("vanished"), atomically: true, encoding: .utf8)
        let result = await GitService.checkout(branch: "vanished", at: root.path)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("vanished")), "local edits")
        let branch = await CommandRunner.run(command: "git symbolic-ref --short HEAD", cwd: root.path)
        XCTAssertEqual(branch.output.trimmingCharacters(in: .newlines), "main")
        let local = await CommandRunner.run(command: "git show-ref --verify --quiet refs/heads/vanished", cwd: root.path)
        XCTAssertNotEqual(local.status, 0)
    }

    @MainActor
    func testOptionInputsAndHistoryShorthandCannotModifyBranchOrWorktree() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git switch -qc other && git switch -q main && printf staged > vanished && git add vanished && printf working > vanished", cwd: root.path)
        let original = await CommandRunner.run(command: "git rev-parse HEAD", cwd: root.path)
        for value in ["--detach", "--force", "--orphan", "@{-1}", "HEAD", "bad\0name"] {
            let create = await GitService.createBranch(value, checkout: true, at: root.path)
            XCTAssertNotEqual(create.status, 0, value)
            let checkout = await GitService.checkout(branch: value, at: root.path)
            XCTAssertNotEqual(checkout.status, 0, value)
            let delete = await GitService.deleteBranch(value, force: true, at: root.path)
            XCTAssertNotEqual(delete.status, 0, value)
            let rename = await GitService.renameBranch("other", to: value, at: root.path)
            XCTAssertNotEqual(rename.status, 0, value)
        }
        for value in ["--force", "--orphan", "--delete", "bad\0ref", "no-such-ref"] {
            for checkout in [true, false] {
                let created = await GitService.createBranch("other", checkout: checkout, from: value, at: root.path)
                XCTAssertNotEqual(created.status, 0, value)
            }
            let merged = await GitService.merge(value, at: root.path)
            XCTAssertNotEqual(merged.status, 0, value)
            let rebased = await GitService.rebase(value, at: root.path)
            XCTAssertNotEqual(rebased.status, 0, value)
        }
        let final = await CommandRunner.run(command: "git rev-parse HEAD && git show :vanished", cwd: root.path)
        XCTAssertEqual(final.output, original.output + "staged")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("vanished")), "working")
        let current = await CommandRunner.run(command: "git symbolic-ref --short HEAD", cwd: root.path)
        XCTAssertEqual(current.output.trimmingCharacters(in: .newlines), "main")
    }

    @MainActor
    func testExplicitStartAndQuotedUnicodeBranchLifecycle() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let hash = await CommandRunner.run(command: "git rev-parse HEAD", cwd: root.path)
        let name = "feature/中文'quote"
        let created = await GitService.createBranch(name, checkout: true, from: "HEAD", at: root.path)
        XCTAssertEqual(created.status, 0, created.output)
        let back = await GitService.checkout(branch: "main", at: root.path)
        XCTAssertEqual(back.status, 0, back.output)
        let renamed = await GitService.renameBranch(name, to: name + "2", at: root.path)
        XCTAssertEqual(renamed.status, 0, renamed.output)
        let target = await CommandRunner.run(command: "git rev-parse \(Shell.quote("refs/heads/" + name + "2"))", cwd: root.path)
        XCTAssertEqual(target.output, hash.output)
        let deleted = await GitService.deleteBranch(name + "2", at: root.path)
        XCTAssertEqual(deleted.status, 0, deleted.output)
        let detached = await GitService.createBranch("from-commit", checkout: false, from: hash.output.trimmingCharacters(in: .newlines), at: root.path)
        XCTAssertEqual(detached.status, 0, detached.output)
    }

    @MainActor
    func testRemoteCheckoutRejectsSymbolicOrMissingRefAndInvalidLocalName() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git remote add origin . && git update-ref refs/remotes/origin/topic HEAD && git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/topic", cwd: root.path)
        for remote in ["origin/HEAD", "origin/missing", "origin/bad\0ref"] {
            let result = await GitService.checkoutRemote(remote, localName: "new", at: root.path)
            XCTAssertNotEqual(result.status, 0, remote)
        }
        let invalid = await GitService.checkoutRemote("origin/topic", localName: "--force", at: root.path)
        XCTAssertNotEqual(invalid.status, 0)
        let result = await GitService.checkoutRemote("origin/topic", localName: "topic", at: root.path)
        XCTAssertEqual(result.status, 0, result.output)
        _ = await GitService.checkout(branch: "main", at: root.path)
        let existing = await GitService.checkoutRemote("origin/topic", localName: "topic", at: root.path)
        XCTAssertEqual(existing.status, 0, existing.output)
    }

    @MainActor
    func testNormalMergeAndRebaseStillAcceptNamedTargets() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await CommandRunner.run(command: "git switch -qc topic && printf topic > topic.txt && git add . && git commit -qm topic && git switch -q main", cwd: root.path)
        let merge = await GitService.merge("topic", at: root.path)
        XCTAssertEqual(merge.status, 0, merge.output)
        _ = await CommandRunner.run(command: "git switch -qc branch && printf branch > branch.txt && git add . && git commit -qm branch && git switch -q main && printf later > later.txt && git add . && git commit -qm later && git switch -q branch", cwd: root.path)
        let rebase = await GitService.rebase("main", at: root.path)
        XCTAssertEqual(rebase.status, 0, rebase.output)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("later.txt")), "later")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("branch.txt")), "branch")
    }
}
