import XCTest
@testable import CodeFlightApp

final class GitRemoteManagementTests: XCTestCase {
    @MainActor
    private func fixture() async throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".git-remote-management-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let setup = await CommandRunner.run(command: "git init -q -b main && git config user.name Test && git config user.email test@example.com && git commit -qm initial --allow-empty", cwd: root.path)
        guard setup.status == 0 else { try? FileManager.default.removeItem(at: root); throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: setup.output]) }
        return root
    }

    @MainActor
    func testCredentialsQueriesAndExternalTransportCannotBeSavedOrCloned() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for address in ["https://test-token@example.com/repo.git", "https://u:secret@example.com/r.git", "https://example.com/r.git?token=secret", "https://example.com/r.git#secret", "https://token@[]bad/r.git", "ext::echo bad", "--upload-pack=bad", "https://example.com/a\rmalformed"] {
            let saved = await GitService.remoteAction(.add, name: "origin", url: address, at: root.path)
            XCTAssertNotEqual(saved.status, 0)
            let request = GitCloneRequest(remote: address, parent: root.path, directory: "cloned")
            XCTAssertNotNil(request.validationError)
            let cloned = await GitService.clone(request, taskID: UUID())
            XCTAssertNotEqual(cloned.status, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: request.destination))
        }
        let remotes = await GitService.remotes(at: root.path)
        XCTAssertTrue(remotes.isEmpty)
    }

    @MainActor
    func testRemoteSnapshotRejectsExternalURLChangeOnSaveAndRemoval() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let added = await GitService.remoteAction(.add, name: "origin", url: "/tmp/original with spaces.git", at: root.path)
        XCTAssertEqual(added.status, 0, added.output)
        let before = await GitService.remotes(at: root.path)
        let snapshot = try XCTUnwrap(before.first)
        _ = await CommandRunner.run(command: "git remote set-url origin /tmp/external.git", cwd: root.path)
        let save = await GitService.remoteAction(.setURL, name: "origin", url: "/tmp/new.git", expected: snapshot, at: root.path)
        XCTAssertNotEqual(save.status, 0)
        let remove = await GitService.remoteAction(.remove, name: "origin", url: "", expected: snapshot, at: root.path)
        XCTAssertNotEqual(remove.status, 0)
        let after = await GitService.remotes(at: root.path)
        XCTAssertEqual(after.first?.fetchURL, "/tmp/external.git")
        let latest = try XCTUnwrap(after.first)
        let saved = await GitService.remoteAction(.setURL, name: "origin", url: "/tmp/final with spaces.git", expected: latest, at: root.path)
        XCTAssertEqual(saved.status, 0, saved.output)
        let final = await GitService.remotes(at: root.path)
        let removed = await GitService.remoteAction(.remove, name: "origin", url: "", expected: final.first, at: root.path)
        XCTAssertEqual(removed.status, 0, removed.output)
        let empty = await GitService.remotes(at: root.path)
        XCTAssertTrue(empty.isEmpty)
    }

    @MainActor
    func testInvalidRemoteNamesAndUnsafeReplacementPreserveExistingConfig() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await GitService.remoteAction(.add, name: "origin", url: "git@example.com:team/repo.git", at: root.path)
        for name in ["--all", "bad name", "bad\nname", "bad\0name", "../outside"] {
            let result = await GitService.remoteAction(.remove, name: name, url: "", at: root.path)
            XCTAssertNotEqual(result.status, 0)
        }
        let invalid = await GitService.remoteAction(.setURL, name: "origin", url: "https://token@example.com/repo.git", at: root.path)
        XCTAssertNotEqual(invalid.status, 0)
        let current = await GitService.remotes(at: root.path)
        XCTAssertEqual(current.first?.fetchURL, "git@example.com:team/repo.git")
    }

    @MainActor
    func testLocalCloneAndNormalSSHAddressesRemainSupported() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for source in ["https://example.com/team/repo.git", "ssh://git@example.com:2222/team/repo.git", "git@example.com:team/repo.git", "file:///tmp/repository%20with%20spaces.git", root.path] {
            XCTAssertNil(GitRepositoryAddress.validationError(source), source)
        }
        let request = GitCloneRequest(remote: root.path, parent: root.path, directory: "cloned project")
        let cloned = await GitService.clone(request, taskID: UUID())
        XCTAssertEqual(cloned.status, 0, cloned.output)
        let remotes = await GitService.remotes(at: request.destination)
        XCTAssertEqual(remotes.first?.fetchURL, root.path)
        let invalid = GitCloneRequest(remote: root.path, parent: root.path, directory: "bad\nname")
        XCTAssertNotNil(invalid.validationError)
        let hidden = GitCloneRequest(remote: root.path, parent: root.path, directory: ".git")
        XCTAssertNotNil(hidden.validationError)
    }
}
