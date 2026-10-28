import XCTest
@testable import CodeFlightApp

final class GitUpstreamTests: XCTestCase {
    @MainActor private func fixture() async throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".git-upstream-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = await CommandRunner.run(command: "git init -q --bare remote.git && git init -q -b 'feature/中文' work && git -C work config user.name Test && git -C work config user.email test@example.com && git -C work commit -qm initial --allow-empty && git -C work remote add origin ../remote.git && git -C work push -q origin HEAD:refs/heads/main HEAD:refs/heads/other && git -C work fetch -q origin", cwd: root.path)
        XCTAssertEqual(result.status, 0, result.output)
        return root
    }

    @MainActor func testSetReplaceAndUnsetPreserveHeadIndexAndWorktree() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("work").path
        _ = await CommandRunner.run(command: "printf staged > file && git add file && printf dirty >> file && printf keep > untracked", cwd: path)
        let before = await CommandRunner.run(command: "git rev-parse HEAD && git diff --binary && git diff --cached --binary && git status --porcelain", cwd: path)
        let initialValue = await GitService.upstreamSnapshot(at: path)
        let initial = try XCTUnwrap(initialValue)
        XCTAssertEqual(initial.branch, "feature/中文"); XCTAssertEqual(initial.upstream, "")
        let set = await GitService.setUpstream("refs/remotes/origin/main", snapshot: initial, at: path)
        XCTAssertEqual(set.status, 0, set.output)
        let mainValue = await GitService.upstreamSnapshot(at: path)
        let main = try XCTUnwrap(mainValue)
        XCTAssertEqual(main.upstream, "refs/remotes/origin/main")
        let replace = await GitService.setUpstream("refs/remotes/origin/other", snapshot: main, at: path)
        XCTAssertEqual(replace.status, 0, replace.output)
        let otherValue = await GitService.upstreamSnapshot(at: path)
        let other = try XCTUnwrap(otherValue)
        XCTAssertEqual(other.upstream, "refs/remotes/origin/other")
        let unset = await GitService.setUpstream(nil, snapshot: other, at: path)
        XCTAssertEqual(unset.status, 0, unset.output)
        let final = await GitService.upstreamSnapshot(at: path)
        XCTAssertEqual(final?.upstream, "")
        let after = await CommandRunner.run(command: "git rev-parse HEAD && git diff --binary && git diff --cached --binary && git status --porcelain", cwd: path)
        XCTAssertEqual(before.output, after.output)
    }

    @MainActor func testStaleSnapshotAndInvalidTargetsAreRejected() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("work").path
        let initialValue = await GitService.upstreamSnapshot(at: path)
        let initial = try XCTUnwrap(initialValue)
        for target in ["--help", "refs/heads/feature/中文", "refs/remotes/origin/missing", "refs/remotes/origin/HEAD", "refs/remotes/origin/main\0x"] {
            let result = await GitService.setUpstream(target, snapshot: initial, at: path)
            XCTAssertNotEqual(result.status, 0, target)
        }
        _ = await CommandRunner.run(command: "git branch --set-upstream-to=origin/main", cwd: path)
        let stale = await GitService.setUpstream("refs/remotes/origin/other", snapshot: initial, at: path)
        XCTAssertNotEqual(stale.status, 0)
        let configured = await GitService.upstreamSnapshot(at: path)
        XCTAssertEqual(configured?.upstream, "refs/remotes/origin/main")
        _ = await CommandRunner.run(command: "git switch -qc different", cwd: path)
        let switched = await GitService.setUpstream(nil, snapshot: try XCTUnwrap(configured), at: path)
        XCTAssertNotEqual(switched.status, 0)
        _ = await CommandRunner.run(command: "git switch -q --detach HEAD", cwd: path)
        let detached = await GitService.upstreamSnapshot(at: path)
        XCTAssertNil(detached)
    }

    @MainActor func testGoneUpstreamCanBeRemovedAndUnbornHasNoSnapshot() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("work").path
        _ = await CommandRunner.run(command: "git branch --set-upstream-to=origin/main && git update-ref -d refs/remotes/origin/main", cwd: path)
        let value = await GitService.upstreamSnapshot(at: path)
        let gone = try XCTUnwrap(value)
        XCTAssertEqual(gone.upstream, "refs/remotes/origin/main")
        let unset = await GitService.setUpstream(nil, snapshot: gone, at: path)
        XCTAssertEqual(unset.status, 0, unset.output)
        _ = await CommandRunner.run(command: "git init -q unborn", cwd: root.path)
        let unborn = await GitService.upstreamSnapshot(at: root.appendingPathComponent("unborn").path)
        XCTAssertNil(unborn)
    }
}
