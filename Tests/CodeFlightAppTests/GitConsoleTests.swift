import XCTest
@testable import CodeFlightApp

@MainActor
final class GitConsoleTests: XCTestCase {
    private var workspace: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<800 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for console operation")
    }

    func testRealGitFailureCannotBeOverwrittenByRunOutputAndConsoleClearLeavesRunAlone() async throws {
        let root = workspace.appendingPathComponent(".console-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let initialized = await CommandRunner.run(command: "git init -q", cwd: root.path)
        XCTAssertEqual(initialized.status, 0)
        let model = WorkbenchModel(restoringSession: false)
        let project = Project(name: "console", path: root.path)
        model.projects = [project]; model.selectedProjectID = project.id
        model.runCommand(command: "while true; do printf 'run-tick\\n'; sleep 0.1; done")
        defer { model.stopCommand() }
        try await waitUntil { model.runningTasks[project.id]?.first?.output.hasSuffix("run-tick\n") == true }
        model.checkoutBranch("missing-console-test-branch")
        try await waitUntil { !model.isGitBusy }
        let entry = try XCTUnwrap(model.selectedGitConsoleEntry)
        XCTAssertEqual(entry.title, "切换分支")
        XCTAssertNotEqual(entry.status, 0)
        XCTAssertTrue(entry.output.contains("missing-console-test-branch"))
        XCTAssertNotNil(model.errorConsoleReference)
        try await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertEqual(model.selectedGitConsoleEntry?.output, entry.output)
        XCTAssertTrue(model.commandOutput.contains("run-tick"))
        XCTAssertFalse(model.commandOutput.contains("missing-console-test-branch"))
        model.revealErrorInConsole()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.selectedGitConsoleEntry?.id, entry.id)
        model.clearGitConsole()
        XCTAssertTrue(model.gitConsoleEntries[project.id]?.isEmpty == true)
        XCTAssertTrue(model.runningTasks[project.id]?.first?.isRunning == true)
        model.stopCommand()
        try await waitUntil { model.runningTasks[project.id]?.first?.isRunning == false }
        XCTAssertTrue(model.gitConsoleEntries[project.id]?.isEmpty == true)
    }

    func testBackgroundHistoryIsBoundedIndependentAndReleasedOnProjectClose() {
        let model = WorkbenchModel(restoringSession: false)
        let first = Project(name: "first", path: workspace.path)
        let second = Project(name: "second", path: workspace.appendingPathComponent("CodeFlight").path)
        model.projects = [first, second]; model.selectedProjectID = second.id
        model.commandOutput = "second-run"
        for index in 0..<30 {
            let id = model.beginGitConsoleEntry(projectID: first.id, title: "operation-\(index)")
            model.finishGitConsoleEntry(id, projectID: first.id, result: CommandResult(output: "line-\(index)", status: 1), presentError: true)
        }
        XCTAssertLessThanOrEqual(model.gitConsoleEntries[first.id]?.count ?? 0, 20)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.selectedGitConsoleEntry)
        XCTAssertEqual(model.commandOutput, "second-run")
        for _ in 0..<10 {
            let id = model.beginGitConsoleEntry(projectID: first.id, title: "large")
            model.finishGitConsoleEntry(id, projectID: first.id, result: CommandResult(output: String(repeating: "中", count: 20_000), status: 0), presentError: true)
        }
        let entries = model.gitConsoleEntries[first.id, default: []]
        XCTAssertLessThanOrEqual(entries.reduce(0) { $0 + $1.output.unicodeScalars.count }, 64_000)
        XCTAssertTrue(entries.last?.truncated == true)
        model.selectedProjectID = first.id
        XCTAssertEqual(model.selectedGitConsoleEntry?.title, "large")
        let pending = model.beginGitConsoleEntry(projectID: first.id, title: "in progress")
        model.clearGitConsole()
        XCTAssertEqual(model.gitConsoleEntries[first.id]?.map(\.id), [pending])
        model.finishGitConsoleEntry(pending, projectID: first.id, result: CommandResult(output: "done", status: 0), presentError: false)
        model.selectedProjectID = second.id
        model.closeProject(first.id)
        XCTAssertNil(model.gitConsoleEntries[first.id])
        XCTAssertNil(model.selectedGitConsoleEntryIDs[first.id])
        XCTAssertEqual(model.commandOutput, "second-run")
    }

    func testNewDiagnosticDoesNotRevealAnOlderGitErrorAndTimeoutSurvivesExistingStream() async {
        let model = WorkbenchModel(restoringSession: false)
        let project = Project(name: "test", path: workspace.path)
        model.projects = [project]; model.selectedProjectID = project.id
        let id = model.beginGitConsoleEntry(projectID: project.id, title: "failed")
        model.finishGitConsoleEntry(id, projectID: project.id, result: CommandResult(output: "old-error", status: 1), presentError: true)
        model.errorMessage = "new-diagnostic"
        XCTAssertNil(model.errorConsoleReference)
        model.revealErrorInConsole()
        XCTAssertEqual(model.selectedGitConsoleEntry?.output, "new-diagnostic")
        let stream = RunOutputStream { _ in }
        // Seed existing output deterministically. Login-shell startup can
        // legitimately take longer than the deliberately short timeout.
        stream.append("started")
        let result = await CommandRunner.run(command: "sleep 8", cwd: workspace.path, timeoutSeconds: 0.1) { stream.append($0) }
        let snapshot = stream.finish(fallback: result.output)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(snapshot.text.contains("started"))
        XCTAssertTrue(snapshot.text.contains("Command timed out"))
    }
}
