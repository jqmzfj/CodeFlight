import XCTest
import Combine
@testable import CodeFlightApp

final class PreviewRefreshTests: XCTestCase {
    @MainActor
    private func fixture() async throws -> (URL, WorkbenchModel, Project) {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".git-preview-refresh-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("original\n".utf8).write(to: root.appendingPathComponent("preview.txt"))
        let result = await CommandRunner.run(command: "git init -q -b main && git add . && git -c user.name=Test -c user.email=test@example.com commit -qm initial", cwd: root.path)
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: root)
            throw NSError(domain: "PreviewFixture", code: Int(result.status))
        }
        let model = WorkbenchModel(restoringSession: false)
        let project = Project(name: "test", path: root.path)
        model.projects = [project]; model.selectedProjectID = project.id
        return (root, model, project)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Preview did not settle within five seconds")
    }

    @MainActor
    func testRefreshPreservesPreviewAndExplicitCloseWhileStillDetectingExternalChanges() async throws {
        let (root, model, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("preview.txt")
        model.openFilePath(file.path)
        try await waitUntil { model.fileContent == "original\n" }
        var updates: [String] = []
        let subscription = model.$fileContent.dropFirst().sink { updates.append($0) }
        defer { subscription.cancel() }
        await model.refreshProject(project)
        XCTAssertEqual(model.fileContent, "original\n")
        XCTAssertTrue(updates.isEmpty, "Unchanged preview must not be removed or republished")

        try Data("external edit\n".utf8).write(to: file, options: .atomic)
        await model.refreshProject(project)
        try await waitUntil { model.fileContent == "external edit\n" }
        XCTAssertFalse(updates.contains(""), "Refreshing a file must keep the old preview until its replacement arrives")

        model.closePreview()
        await model.refreshProject(project)
        XCTAssertEqual(model.selectedFile, "")
        XCTAssertEqual(model.fileContent, "")
        XCTAssertEqual(model.diffContent, "")
    }

    @MainActor
    func testDeletedPreviewClosesWithoutOpeningAnotherFile() async throws {
        let (root, model, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("preview.txt")
        try Data("other\n".utf8).write(to: root.appendingPathComponent("other.txt"))
        model.openFilePath(file.path)
        try await waitUntil { model.fileContent == "original\n" }
        try FileManager.default.removeItem(at: file)
        await model.refreshProject(project)
        XCTAssertEqual(model.selectedFile, "")
        XCTAssertEqual(model.fileContent, "")
    }

    @MainActor
    func testRefreshPreservesDiffUntilReplacementArrives() async throws {
        let (root, model, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("preview.txt")
        try Data("changed\n".utf8).write(to: file)
        let status = await GitService.status(at: root.path)
        let change = try XCTUnwrap(status.changes.first)
        model.openDiff(change)
        try await waitUntil { model.diffContent.contains("+changed") }
        let original = model.diffContent
        var updates: [String] = []
        let subscription = model.$diffContent.dropFirst().sink { updates.append($0) }
        defer { subscription.cancel() }
        await model.refreshProject(project)
        XCTAssertEqual(model.diffContent, original)
        XCTAssertTrue(updates.isEmpty)
        try Data("external diff\n".utf8).write(to: file, options: .atomic)
        await model.refreshProject(project)
        try await waitUntil { model.diffContent.contains("+external diff") }
        XCTAssertFalse(updates.contains { $0.isEmpty || $0.contains("Loading diff") })
    }

    @MainActor
    func testClosingProjectDuringGitOperationKeepsTabUntilOperationFinishes() async throws {
        let (root, model, project) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults.standard
        let recent = defaults.object(forKey: "recentProjectPaths")
        let selected = defaults.object(forKey: "selectedProjectPath")
        defer {
            if let recent { defaults.set(recent, forKey: "recentProjectPaths") } else { defaults.removeObject(forKey: "recentProjectPaths") }
            if let selected { defaults.set(selected, forKey: "selectedProjectPath") } else { defaults.removeObject(forKey: "selectedProjectPath") }
        }
        model.createBranch("operation-check", checkout: false)
        XCTAssertTrue(model.isGitBusy)
        model.closeProject(project.id)
        XCTAssertEqual(model.projects.count, 1)
        XCTAssertEqual(model.selectedProjectID, project.id)
        XCTAssertNotNil(model.errorMessage)
        try await waitUntil { !model.isGitBusy }
        let branches = await GitService.branches(at: root.path)
        XCTAssertTrue(branches.contains("operation-check"))
        model.closeProject(project.id)
        XCTAssertTrue(model.projects.isEmpty)
    }

    @MainActor
    func testImmediateStopPreventsQueuedCommandFromStarting() async throws {
        let (root, model, project) = try await fixture()
        defer { CommandRunner.stop(projectID: project.id); try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("should-not-run")
        model.runCommand(command: "printf started > should-not-run")
        model.stopCommand()
        // Give the queued main-actor task an opportunity to start. It must
        // recheck cancellation before invoking a shell or touching disk.
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(CommandRunner.hasRunningProcesses(projectID: project.id))
        model.runCommand(command: "printf restarted > should-not-run")
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        XCTAssertEqual(try String(contentsOf: marker), "restarted")
    }

    @MainActor
    func testStopAllTracksCommandsWithoutProjectOrTaskID() async throws {
        let (root, _, _) = try await fixture()
        defer { CommandRunner.stopAll(); try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("command-started")
        let operation = Task { await CommandRunner.run(command: "printf ready > command-started; sleep 30", cwd: root.path) }
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        XCTAssertTrue(CommandRunner.hasRunningCommands)
        CommandRunner.stopAll()
        let result = await operation.value
        XCTAssertNotEqual(result.status, 0)
    }

    @MainActor
    func testStoppingRunningCommandKeepsStoppedStatusAfterProcessExits() async throws {
        let (root, model, project) = try await fixture()
        defer { CommandRunner.stop(projectID: project.id); try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("running")
        model.runCommand(command: "printf ready > running; sleep 30")
        try await waitUntil { FileManager.default.fileExists(atPath: marker.path) }
        model.stopCommand()
        try await waitUntil { model.commandOutput.contains("命令已停止") }
        let task = try XCTUnwrap(model.runningTasks[project.id]?.first)
        XCTAssertTrue(task.wasStopped)
        XCTAssertEqual(task.exitCode, -15)
        XCTAssertFalse(task.output.contains("命令失败"))
    }
}
