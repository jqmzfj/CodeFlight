import XCTest
@testable import CodeFlightApp

final class GitSubmoduleTests: XCTestCase {
    private var workspaceRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }

    @MainActor
    private func fixture() async throws -> URL {
        let root = workspaceRoot.appendingPathComponent(".git-submodule-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let setup = await CommandRunner.run(command: "mkdir source parent && git -C source init -q -b main && git -C source config user.name Test && git -C source config user.email test@example.com && printf original > source/file.txt && git -C source add . && git -C source commit -qm original && git -C parent init -q -b main && git -C parent config user.name Test && git -C parent config user.email test@example.com && git -C parent -c protocol.file.allow=always submodule add -q ../source 'modules/child [1]' && git -C parent commit -qam submodule", cwd: root.path)
        guard setup.status == 0 else {
            try? FileManager.default.removeItem(at: root)
            throw NSError(domain: "SubmoduleFixture", code: Int(setup.status), userInfo: [NSLocalizedDescriptionKey: setup.output])
        }
        return root
    }

    @MainActor
    func testSubmoduleDiscoveryAndReinitializationFromPinnedCommit() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent")
        let result = await GitService.submodules(at: parent.path)
        XCTAssertNil(result.1)
        let module = try XCTUnwrap(result.0.first)
        XCTAssertEqual(module.path, "modules/child [1]")
        let initial = await GitService.submoduleState(module)
        XCTAssertTrue(initial.initialized)
        XCTAssertEqual(initial.hash, module.expectedHash)
        XCTAssertFalse(initial.dirty)
        let deinitResult = await CommandRunner.run(command: "git submodule deinit -f -- 'modules/child [1]'", cwd: parent.path)
        XCTAssertEqual(deinitResult.status, 0, deinitResult.output)
        let empty = await GitService.submoduleState(module)
        XCTAssertFalse(empty.initialized)
        let initialized = await GitService.submoduleAction(.update, module: module, recursive: true)
        XCTAssertEqual(initialized.status, 0, initialized.output)
        let restored = await GitService.submoduleState(module)
        XCTAssertTrue(restored.initialized)
        XCTAssertEqual(restored.hash, module.expectedHash)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: module.absolutePath).appendingPathComponent("file.txt")), "original")
    }

    @MainActor
    func testSubmoduleUpdateRefusesDirtyOverwriteAndRejectsStalePin() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent")
        let initial = await GitService.submodules(at: parent.path)
        let old = try XCTUnwrap(initial.0.first)
        let advance = await CommandRunner.run(command: "printf next > source/file.txt && git -C source commit -qam next && git -C 'parent/modules/child [1]' fetch -q origin", cwd: root.path)
        XCTAssertEqual(advance.status, 0, advance.output)
        let hashResult = await GitService.commitHash("HEAD", at: root.appendingPathComponent("source").path)
        let hash = try XCTUnwrap(hashResult)
        let pin = await CommandRunner.run(command: "git update-index --cacheinfo 160000,\(hash),'modules/child [1]'", cwd: parent.path)
        XCTAssertEqual(pin.status, 0, pin.output)
        let stale = await GitService.submoduleAction(.update, module: old, recursive: false)
        XCTAssertNotEqual(stale.status, 0)
        let latest = await GitService.submodules(at: parent.path)
        let module = try XCTUnwrap(latest.0.first)
        let file = URL(fileURLWithPath: module.absolutePath).appendingPathComponent("file.txt")
        try Data("local edits".utf8).write(to: file)
        let state = await GitService.submoduleState(module)
        XCTAssertTrue(state.dirty)
        let refused = await GitService.submoduleAction(.update, module: module, recursive: false)
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertEqual(try String(contentsOf: file), "local edits")
        let preserved = await GitService.commitHash("HEAD", at: module.absolutePath)
        XCTAssertEqual(preserved, old.expectedHash)
        try Data("original".utf8).write(to: file)
        let updated = await GitService.submoduleAction(.update, module: module, recursive: false)
        XCTAssertEqual(updated.status, 0, updated.output)
        XCTAssertEqual(try String(contentsOf: file), "next")
        let checkedOut = await GitService.commitHash("HEAD", at: module.absolutePath)
        XCTAssertEqual(checkedOut, hash)
    }

    @MainActor
    func testSubmoduleSyncAndInvalidConfiguration() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent")
        let original = await GitService.submodules(at: parent.path)
        let old = try XCTUnwrap(original.0.first)
        let changed = await CommandRunner.run(command: "git config --file .gitmodules 'submodule.modules/child [1].url' https://example.com/child.git", cwd: parent.path)
        XCTAssertEqual(changed.status, 0, changed.output)
        let stale = await GitService.submoduleAction(.sync, module: old, recursive: false)
        XCTAssertNotEqual(stale.status, 0)
        let current = await GitService.submodules(at: parent.path)
        let module = try XCTUnwrap(current.0.first)
        let synced = await GitService.submoduleAction(.sync, module: module, recursive: true)
        XCTAssertEqual(synced.status, 0, synced.output)
        let url = await CommandRunner.run(command: "git config 'submodule.modules/child [1].url'", cwd: parent.path)
        XCTAssertEqual(url.output.trimmingCharacters(in: .whitespacesAndNewlines), "https://example.com/child.git")
        _ = await CommandRunner.run(command: "git config --file .gitmodules 'submodule.modules/child [1].path' ../outside", cwd: parent.path)
        let invalid = await GitService.submodules(at: parent.path)
        XCTAssertTrue(invalid.0.isEmpty)
        XCTAssertNotNil(invalid.1)
        _ = await CommandRunner.run(command: "git config --file .gitmodules 'submodule.modules/child [1].path' missing-gitlink", cwd: parent.path)
        let missing = await GitService.submodules(at: parent.path)
        XCTAssertTrue(missing.0.isEmpty)
        XCTAssertNotNil(missing.1)
    }

    @MainActor
    func testSubmoduleFirstInitializationUsesTemporaryHTTPCredentials() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let serverScript = root.appendingPathComponent("server.py")
        let portFile = root.appendingPathComponent("port")
        let script = """
        import base64, http.server, os, sys
        os.chdir(sys.argv[1])
        expected = 'Basic ' + base64.b64encode(b'test-user:test-token').decode()
        class Handler(http.server.SimpleHTTPRequestHandler):
            def do_GET(self):
                if self.headers.get('Authorization') != expected:
                    self.send_response(401)
                    self.send_header('WWW-Authenticate', 'Basic realm="Submodule test"')
                    self.end_headers()
                    return
                super().do_GET()
            def log_message(self, *args):
                pass
        server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        with open(sys.argv[2], 'w') as output:
            output.write(str(server.server_port))
        server.serve_forever()
        """
        try Data(script.utf8).write(to: serverScript)
        let prepare = await CommandRunner.run(command: "git -C source update-server-info", cwd: root.path)
        XCTAssertEqual(prepare.status, 0, prepare.output)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        server.arguments = ["python3", serverScript.path, root.appendingPathComponent("source/.git").path, portFile.path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { if server.isRunning { server.terminate(); server.waitUntilExit() } }
        var port: String?
        for _ in 0..<200 {
            if let value = try? String(contentsOf: portFile), !value.isEmpty { port = value; break }
            guard server.isRunning else { throw NSError(domain: "SubmoduleHTTP", code: 1) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let readyPort = try XCTUnwrap(port)
        let remote = "http://127.0.0.1:" + readyPort
        let setup = await CommandRunner.run(command: "git -C parent config --file .gitmodules 'submodule.modules/child [1].url' \(Shell.quote(remote)) && git -C parent commit -qam http-fixture && git clone -q parent cloned", cwd: root.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        let cloned = root.appendingPathComponent("cloned")
        let listed = await GitService.submodules(at: cloned.path)
        let module = try XCTUnwrap(listed.0.first)
        let initial = await GitService.submoduleState(module)
        XCTAssertFalse(initial.initialized)
        let initialized = await GitService.submoduleAction(.update, module: module, recursive: true, credentials: GitCredentials(username: "test-user", secret: "test-token"))
        XCTAssertEqual(initialized.status, 0, initialized.output)
        XCTAssertFalse(initialized.output.contains("test-token"))
        let state = await GitService.submoduleState(module)
        XCTAssertEqual(state.hash, module.expectedHash)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: module.absolutePath).appendingPathComponent("file.txt")), "original")
        let added = await GitService.addSubmodule(GitSubmoduleAddRequest(source: remote, destination: "added-http"), at: cloned.path, credentials: GitCredentials(username: "test-user", secret: "test-token"))
        XCTAssertEqual(added.status, 0, added.output)
        XCTAssertFalse(added.output.contains("test-token"))
        let gitmodules = try String(contentsOf: cloned.appendingPathComponent(".gitmodules"))
        XCTAssertFalse(gitmodules.contains("test-token"))
        for path in [cloned.path, module.absolutePath, cloned.appendingPathComponent("added-http").path] {
            let config = await CommandRunner.run(command: "git config --local --list", cwd: path)
            XCTAssertFalse(config.output.contains("test-token"))
            XCTAssertFalse(config.output.contains("test-user"))
        }
    }

    func testSubmoduleURLLabelRedactsCredentials() {
        let module = GitSubmodule(root: "/tmp", path: "child", url: "https://test-user:test-token@example.com/child.git?token=private#secret", expectedHash: "")
        XCTAssertEqual(module.displayURL, "https://example.com/child.git")
    }
    @MainActor
    func testAddAndRemoveSubmodulePreserveUnrelatedParentIndexAndHistory() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent")
        let setup = await CommandRunner.run(command: "printf original > notes.txt && git add notes.txt && git commit -qm notes && printf staged > notes.txt && git add notes.txt && printf unstaged > notes.txt", cwd: parent.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        let before = await CommandRunner.run(command: "git rev-parse :notes.txt", cwd: parent.path)
        let request = GitSubmoduleAddRequest(source: "../source", destination: "libraries/new [2]")
        let added = await GitService.addSubmodule(request, at: parent.path)
        XCTAssertEqual(added.status, 0, added.output)
        let listed = await GitService.submodules(at: parent.path)
        XCTAssertNil(listed.1)
        XCTAssertEqual(listed.0.count, 2)
        let module = try XCTUnwrap(listed.0.first { $0.path == request.destination })
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: module.absolutePath).appendingPathComponent("file.txt")), "original")
        let uncommitted = await GitService.removeSubmodule(module)
        XCTAssertNotEqual(uncommitted.status, 0)
        _ = await CommandRunner.run(command: "git commit -qm added --only -- .gitmodules 'libraries/new [2]'", cwd: parent.path)
        let removed = await GitService.removeSubmodule(module)
        XCTAssertEqual(removed.status, 0, removed.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: module.absolutePath))
        let remaining = await GitService.submodules(at: parent.path)
        XCTAssertEqual(remaining.0.map(\.path), ["modules/child [1]"])
        let metadata = await CommandRunner.run(command: "git --git-dir='.git/modules/libraries/new [2]' --work-tree=. rev-parse HEAD", cwd: parent.path)
        XCTAssertEqual(metadata.output.trimmingCharacters(in: .newlines), module.expectedHash)
        let after = await CommandRunner.run(command: "git rev-parse :notes.txt", cwd: parent.path)
        XCTAssertEqual(before.output, after.output)
        XCTAssertEqual(try String(contentsOf: parent.appendingPathComponent("notes.txt")), "unstaged")
        let status = await GitService.status(at: parent.path)
        XCTAssertTrue(status.changes.contains { $0.path == request.destination && $0.isStaged })
        XCTAssertTrue(status.changes.contains { $0.path == ".gitmodules" && $0.isStaged })
    }

    @MainActor
    func testRemovalRejectsModifiedUntrackedIgnoredAndDifferentCheckout() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent")
        let listed = await GitService.submodules(at: parent.path)
        let module = try XCTUnwrap(listed.0.first)
        let child = URL(fileURLWithPath: module.absolutePath)
        let configurations = ["printf dirty > file.txt", "printf keep > untracked.txt", "git config core.excludesFile \(Shell.quote(root.appendingPathComponent("ignore-list").path)) && printf ignored.txt > \(Shell.quote(root.appendingPathComponent("ignore-list").path)) && printf keep > ignored.txt"]
        for command in configurations {
            let setup = await CommandRunner.run(command: command, cwd: child.path)
            XCTAssertEqual(setup.status, 0, setup.output)
            let result = await GitService.removeSubmodule(module)
            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
            _ = await CommandRunner.run(command: "git restore file.txt && rm -f untracked.txt ignored.txt", cwd: child.path)
        }
        _ = await CommandRunner.run(command: "git -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m local-only", cwd: child.path)
        let different = await GitService.removeSubmodule(module)
        XCTAssertNotEqual(different.status, 0)
        let log = await CommandRunner.run(command: "git log -1 --format=%s", cwd: child.path)
        XCTAssertEqual(log.output.trimmingCharacters(in: .newlines), "local-only")
    }

    @MainActor
    func testAddAndRemoveRefuseChangedConfigurationAndStalePin() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent")
        let listed = await GitService.submodules(at: parent.path)
        let module = try XCTUnwrap(listed.0.first)
        _ = await CommandRunner.run(command: "printf '\\n# preserve my edit\\n' >> .gitmodules && git add .gitmodules", cwd: parent.path)
        let before = try Data(contentsOf: parent.appendingPathComponent(".gitmodules"))
        let index = await CommandRunner.run(command: "git ls-files --stage -z", cwd: parent.path)
        let add = await GitService.addSubmodule(GitSubmoduleAddRequest(source: "../source", destination: "other"), at: parent.path)
        let remove = await GitService.removeSubmodule(module)
        XCTAssertNotEqual(add.status, 0); XCTAssertNotEqual(remove.status, 0)
        XCTAssertEqual(try Data(contentsOf: parent.appendingPathComponent(".gitmodules")), before)
        let after = await CommandRunner.run(command: "git ls-files --stage -z", cwd: parent.path)
        XCTAssertEqual(index.output, after.output)
        _ = await CommandRunner.run(command: "git restore --staged --worktree .gitmodules && git config --file .gitmodules 'submodule.modules/child [1].url' https://example.com/new.git && git commit -qam changed", cwd: parent.path)
        let stale = await GitService.removeSubmodule(module)
        XCTAssertNotEqual(stale.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: module.absolutePath))
    }

    @MainActor
    func testAddRejectsUnsafePathsExistingTargetsAndCredentialURLs() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent")
        for destination in ["../outside", "/tmp/outside", "a/../outside", "a/.git/x", "a/.GIT/x", "a//x", "--force", ".gitmodules/x", "bad\nname"] {
            let result = await GitService.addSubmodule(GitSubmoduleAddRequest(source: "../source", destination: destination), at: parent.path)
            XCTAssertNotEqual(result.status, 0, destination)
        }
        for source in ["--force", "ext::touch injected", "https://user:password@example.com/repo", "https://token@example.com/repo", "https://example.com/repo?token=private"] {
            let result = await GitService.addSubmodule(GitSubmoduleAddRequest(source: source, destination: "new"), at: parent.path)
            XCTAssertNotEqual(result.status, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("new").path))
        }
        try FileManager.default.createSymbolicLink(at: parent.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("source"))
        let linked = await GitService.addSubmodule(GitSubmoduleAddRequest(source: "../source", destination: "link/child"), at: parent.path)
        XCTAssertNotEqual(linked.status, 0)
        _ = await CommandRunner.run(command: "mkdir existing && printf keep > existing/keep.txt", cwd: parent.path)
        let existing = await GitService.addSubmodule(GitSubmoduleAddRequest(source: "../source", destination: "existing"), at: parent.path)
        XCTAssertNotEqual(existing.status, 0)
        XCTAssertEqual(try String(contentsOf: parent.appendingPathComponent("existing/keep.txt")), "keep")
    }

    @MainActor
    func testUninitializedSubmoduleRemovalRefusesResidualFilesAndCanRemoveEmptyCheckout() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent")
        let listed = await GitService.submodules(at: parent.path)
        let module = try XCTUnwrap(listed.0.first)
        _ = await CommandRunner.run(command: "git submodule deinit -f -- 'modules/child [1]'", cwd: parent.path)
        let file = URL(fileURLWithPath: module.absolutePath).appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)
        let refused = await GitService.removeSubmodule(module)
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertEqual(try String(contentsOf: file), "keep")
        try FileManager.default.removeItem(at: file)
        let removed = await GitService.removeSubmodule(module)
        XCTAssertEqual(removed.status, 0, removed.output)
        let remaining = await GitService.submodules(at: parent.path)
        XCTAssertTrue(remaining.0.isEmpty)
    }

    @MainActor
    func testRemovalInspectsIgnoredFilesInNestedSubmodules() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent")
        let listed = await GitService.submodules(at: parent.path)
        let old = try XCTUnwrap(listed.0.first)
        let child = URL(fileURLWithPath: old.absolutePath)
        let setup = await CommandRunner.run(command: "git config user.name Test && git config user.email test@example.com && git -c protocol.file.allow=always submodule add -q \(Shell.quote(root.appendingPathComponent("source").path)) nested && git commit -qam nested", cwd: child.path)
        XCTAssertEqual(setup.status, 0, setup.output)
        _ = await CommandRunner.run(command: "git add 'modules/child [1]' && git commit -qm pin", cwd: parent.path)
        let latest = await GitService.submodules(at: parent.path)
        let module = try XCTUnwrap(latest.0.first)
        let nested = child.appendingPathComponent("nested")
        let ignored = await CommandRunner.run(command: "git config core.excludesFile \(Shell.quote(root.appendingPathComponent("ignore-list").path)) && printf ignored.txt > \(Shell.quote(root.appendingPathComponent("ignore-list").path)) && printf keep > ignored.txt", cwd: nested.path)
        XCTAssertEqual(ignored.status, 0, ignored.output)
        let refused = await GitService.removeSubmodule(module)
        XCTAssertNotEqual(refused.status, 0)
        XCTAssertEqual(try String(contentsOf: nested.appendingPathComponent("ignored.txt")), "keep")
        try FileManager.default.removeItem(at: nested.appendingPathComponent("ignored.txt"))
        let removed = await GitService.removeSubmodule(module)
        XCTAssertEqual(removed.status, 0, removed.output)
    }

    @MainActor
    func testRemovalRefusesAnOpenSubmoduleProjectWithoutRemovingFiles() async throws {
        let root = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent")
        let listed = await GitService.submodules(at: parent.path)
        let module = try XCTUnwrap(listed.0.first)
        let model = WorkbenchModel(restoringSession: false)
        let parentProject = Project(name: "parent", path: parent.path)
        let childProject = Project(name: "child", path: module.absolutePath)
        model.projects = [parentProject, childProject]; model.selectedProjectID = parentProject.id
        var result: CommandResult?
        model.removeSubmodule(module) { result = $0 }
        XCTAssertNotEqual(try XCTUnwrap(result).status, 0)
        XCTAssertEqual(model.projects.count, 2)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: module.absolutePath).appendingPathComponent("file.txt")), "original")
        let remaining = await GitService.submodules(at: parent.path)
        XCTAssertEqual(remaining.0.count, 1)
    }

}
