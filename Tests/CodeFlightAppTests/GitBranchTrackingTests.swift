import XCTest
@testable import CodeFlightApp

final class GitBranchTrackingTests: XCTestCase {
    @MainActor private func fixture() async throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".git-tracking-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let setup = await CommandRunner.run(command: "git init -q --bare remote.git && git init -q -b main work && git -C work config user.name Test && git -C work config user.email test@example.com && git -C work commit -qm initial --allow-empty && git -C work remote add origin ../remote.git && git -C work push -qu origin main && git clone -q -b main remote.git peer && git -C peer config user.name Peer && git -C peer config user.email peer@example.com", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        return root
    }
    @MainActor func testCountsTrackLocalRemoteFetchAndDivergenceWithoutAutomaticNetwork() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work").path, peer = root.appendingPathComponent("peer").path
        let initial = await GitService.status(at: work)
        XCTAssertEqual(initial.tracking.upstream, "origin/main")
        XCTAssertEqual(initial.tracking.ahead, 0)
        XCTAssertEqual(initial.tracking.behind, 0)
        _ = await CommandRunner.run(command: "git commit -qm remote-change --allow-empty && git push -q origin main", cwd: peer)
        let unfetched = await GitService.status(at: work)
        XCTAssertEqual(unfetched.tracking.behind, 0, "Status uses fetched refs, not the server")
        let fetched = await GitService.fetch(remote: "origin", at: work)
        XCTAssertEqual(fetched.status, 0, fetched.output)
        let behind = await GitService.status(at: work)
        XCTAssertEqual(behind.tracking.ahead, 0)
        XCTAssertEqual(behind.tracking.behind, 1)
        _ = await CommandRunner.run(command: "git commit -qm local-change --allow-empty", cwd: work)
        let diverged = await GitService.status(at: work)
        XCTAssertEqual(diverged.tracking.ahead, 1)
        XCTAssertEqual(diverged.tracking.behind, 1)
        let before = await CommandRunner.run(command: "git rev-parse HEAD && git status --porcelain", cwd: work)
        _ = await GitService.status(at: work)
        let after = await CommandRunner.run(command: "git rev-parse HEAD && git status --porcelain", cwd: work)
        XCTAssertEqual(before.output, after.output)
        _ = await CommandRunner.run(command: "git merge -q --no-edit origin/main", cwd: work)
        let merged = await GitService.status(at: work)
        XCTAssertEqual(merged.tracking.behind, 0)
        XCTAssertEqual(merged.tracking.ahead, 2)
        let pushed = await GitService.push(remote: "origin", branch: "main", setUpstream: false, at: work)
        XCTAssertEqual(pushed.status, 0, pushed.output)
        let synced = await GitService.status(at: work)
        XCTAssertEqual(synced.tracking.ahead, 0)
        XCTAssertEqual(synced.tracking.behind, 0)
    }

    @MainActor func testGoneUpstreamAndFetchRecovery() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work").path
        _ = await CommandRunner.run(command: "git update-ref -d refs/remotes/origin/main", cwd: work)
        let gone = await GitService.status(at: work)
        XCTAssertEqual(gone.tracking.upstream, "origin/main")
        XCTAssertTrue(gone.tracking.gone)
        XCTAssertNil(gone.tracking.ahead)
        XCTAssertNil(gone.tracking.behind)
        _ = await GitService.fetch(remote: "origin", at: work)
        let recovered = await GitService.status(at: work)
        XCTAssertFalse(recovered.tracking.gone)
        XCTAssertEqual(recovered.tracking.ahead, 0)
        _ = await CommandRunner.run(command: "git branch --unset-upstream", cwd: work)
        let untracked = await GitService.status(at: work)
        XCTAssertNil(untracked.tracking.upstream)
        XCTAssertNil(untracked.tracking.ahead)
    }

    @MainActor func testUnbornDetachedAndCountsRemainAvailableWithUserConfig() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("work").path
        _ = await CommandRunner.run(command: "git init -q -b 'feature/中文' unborn", cwd: root.path)
        let unborn = await GitService.status(at: root.appendingPathComponent("unborn").path)
        XCTAssertEqual(unborn.branch, "feature/中文")
        XCTAssertTrue(unborn.tracking.unborn)
        XCTAssertNil(unborn.tracking.upstream)
        _ = await CommandRunner.run(command: "git commit -qm local --allow-empty && git config status.aheadBehind false", cwd: work)
        let unknown = await GitService.status(at: work)
        XCTAssertEqual(unknown.tracking.upstream, "origin/main")
        XCTAssertEqual(unknown.tracking.ahead, 1)
        XCTAssertEqual(unknown.tracking.behind, 0)
        _ = await CommandRunner.run(command: "git switch -q --detach HEAD", cwd: work)
        let detached = await GitService.status(at: work)
        XCTAssertTrue(detached.tracking.detached)
        XCTAssertNil(detached.tracking.upstream)
    }

    func testHeaderParsingPreservesNestedNamesAndDoesNotInventUnknownCounts() {
        let result = GitService.parseBranchHeader("## feature/a...company/team/feature/a [ahead 12, behind 3]")
        XCTAssertEqual(result.branch, "feature/a")
        XCTAssertEqual(result.tracking.upstream, "company/team/feature/a")
        XCTAssertEqual(result.tracking.ahead, 12)
        XCTAssertEqual(result.tracking.behind, 3)
        let unborn = GitService.parseBranchHeader("## No commits yet on master...origin/master [gone]")
        XCTAssertEqual(unborn.branch, "master")
        XCTAssertTrue(unborn.tracking.unborn)
        XCTAssertEqual(unborn.tracking.upstream, "origin/master")
        XCTAssertTrue(unborn.tracking.gone)
        let local = GitService.parseBranchHeader("## release(1)")
        XCTAssertEqual(local.branch, "release(1)")
        XCTAssertNil(local.tracking.upstream)
        for suffix in ["different", "ahead nope", "ahead -1"] {
            let unknown = GitService.parseBranchHeader("## main...origin/main [\(suffix)]")
            XCTAssertNil(unknown.tracking.ahead)
            XCTAssertNil(unknown.tracking.behind)
        }
    }
}
