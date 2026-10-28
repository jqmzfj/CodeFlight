import XCTest
@testable import CodeFlightApp

final class GitComparisonCommitsTests: XCTestCase {
    @MainActor private func fixture() async throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".git-comparison-commits-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let result = await CommandRunner.run(command: "git init -q -b main && git config user.name 'Test 中文' && git config user.email test@example.com && printf base > '特殊 [1].swift' && git add . && git commit -qm base && git branch feature && printf local > local.txt && git add . && git commit -qm current && git switch -q feature && printf target > '特殊 [1].swift' && git add . && git commit -qm '目标提交 | 中文' && git switch -q main", cwd: root.path)
        XCTAssertEqual(result.status, 0, result.output)
        return root
    }

    @MainActor func testBothSidesExcludeSharedHistoryAndPreserveSnapshotAfterBranchMove() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let comparison = await GitService.compareBranches(target: "feature", fromMergeBase: true, at: root.path)
        let snapshot = try XCTUnwrap(comparison.0, comparison.1 ?? "")
        let before = await CommandRunner.run(command: "git rev-parse HEAD && git status --porcelain && git diff --cached --binary", cwd: root.path)
        let current = await GitService.comparisonCommits(snapshot, targetSide: false, at: root.path)
        let target = await GitService.comparisonCommits(snapshot, targetSide: true, at: root.path)
        XCTAssertNil(current.1); XCTAssertNil(target.1)
        XCTAssertEqual(current.0?.commits.map(\.subject), ["current"])
        XCTAssertEqual(target.0?.commits.map(\.subject), ["目标提交 | 中文"])
        XCTAssertEqual(target.0?.commits.first?.author, "Test 中文")
        XCTAssertEqual(target.0?.commits.first?.hash, snapshot.target)
        XCTAssertEqual(target.0?.hasMore, false)
        let diff = await GitService.commitDiff(snapshot.target, file: "特殊 [1].swift", at: root.path)
        XCTAssertTrue(diff.contains("+target"), diff)
        _ = await CommandRunner.run(command: "git branch -f feature main", cwd: root.path)
        let frozen = await GitService.comparisonCommits(snapshot, targetSide: true, at: root.path)
        XCTAssertEqual(frozen.0?.commits.map(\.hash), target.0?.commits.map(\.hash))
        let after = await CommandRunner.run(command: "git rev-parse HEAD && git status --porcelain && git diff --cached --binary", cwd: root.path)
        XCTAssertEqual(before.output, after.output)
        let fresh = await GitService.compareBranches(target: "feature", fromMergeBase: false, at: root.path)
        let same = try XCTUnwrap(fresh.0)
        let empty = await GitService.comparisonCommits(same, targetSide: true, at: root.path)
        XCTAssertEqual(empty.0?.commits.count, 0)
        XCTAssertEqual(empty.0?.hasMore, false)
    }

    @MainActor func testPaginationHasNoDuplicateOrMissingCommits() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let setup = await CommandRunner.run(command: "git switch -q feature && for n in {1..54}; do git commit -qm \"page-$n\" --allow-empty || exit; done && git switch -q main", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        let comparison = await GitService.compareBranches(target: "feature", fromMergeBase: false, at: root.path)
        let snapshot = try XCTUnwrap(comparison.0)
        XCTAssertEqual(snapshot.targetOnly, 55)
        let first = await GitService.comparisonCommits(snapshot, targetSide: true, at: root.path)
        let second = await GitService.comparisonCommits(snapshot, targetSide: true, skip: 50, at: root.path)
        XCTAssertEqual(first.0?.commits.count, 50); XCTAssertEqual(first.0?.hasMore, true)
        XCTAssertEqual(second.0?.commits.count, 5); XCTAssertEqual(second.0?.hasMore, false)
        let hashes = (first.0?.commits ?? []) + (second.0?.commits ?? [])
        XCTAssertEqual(Set(hashes.map(\.hash)).count, 55)
        let expected = await CommandRunner.run(command: "git rev-list main..feature", cwd: root.path)
        XCTAssertEqual(Set(hashes.map(\.hash)), Set(expected.output.split(whereSeparator: \.isNewline).map(String.init)))
        let pastEnd = await GitService.comparisonCommits(snapshot, targetSide: true, skip: 55, at: root.path)
        XCTAssertEqual(pastEnd.0?.commits.count, 0)
    }

    @MainActor func testInvalidAndMissingSnapshotsReturnErrors() async throws {
        let root = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for hash in ["--help", "HEAD; touch unexpected", String(repeating: "0", count: 40)] {
            let invalid = GitBranchComparison(current: hash, target: hash, base: hash, files: [], currentOnly: 0, targetOnly: 0)
            let result = await GitService.comparisonCommits(invalid, targetSide: true, at: root.path)
            XCTAssertNil(result.0); XCTAssertNotNil(result.1)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected").path))
    }
}
