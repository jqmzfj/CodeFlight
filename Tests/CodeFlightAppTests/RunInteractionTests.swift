import XCTest
@testable import CodeFlightApp

@MainActor
final class RunInteractionTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<800 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for run lifecycle")
    }
    private func model() -> (WorkbenchModel, Project) {
        let m = WorkbenchModel(restoringSession: false)
        let p = Project(name: "run-qa", path: root.path)
        m.projects = [p]; m.selectedProjectID = p.id
        return (m, p)
    }
    func testHighVolumeColoredOutputEndsWithBoundedReadableLogAndClearsTruncation() async throws {
        let (m, p) = model()
        m.runCommand(command: "for i in {1..10000}; do printf '\\033[32mrow-%s 中文\\033[0m\\n' \"$i\"; done; printf 'FINISHED\\n'")
        try await waitUntil { m.runningTasks[p.id]?.first?.isRunning == false }
        let task = try XCTUnwrap(m.runningTasks[p.id]?.first)
        XCTAssertEqual(task.exitCode, 0)
        XCTAssertTrue(task.output.hasSuffix("row-10000 中文\nFINISHED\n"))
        XCTAssertFalse(task.output.contains("\u{1B}"))
        XCTAssertLessThanOrEqual(task.output.unicodeScalars.count, 12_000)
        XCTAssertTrue(task.logWasTruncated)
        XCTAssertTrue(m.runOutputStreams.isEmpty)
        m.clearTaskOutput(task.id)
        XCTAssertEqual(m.runningTasks[p.id]?.first?.output, "")
        XCTAssertFalse(m.runningTasks[p.id]?.first?.logWasTruncated == true)
    }

    func testDuplicateConfigurationFocusesExistingSessionAndStopTargetsOnlyOneProcess() async throws {
        let (m, p) = model()
        let config = RunConfiguration(name: "server", command: "printf ready; sleep 30", workingDirectory: "")
        m.projects[0].runConfigurations = [config]; m.selectRunConfiguration(config)
        defer { m.stopCommand() }
        m.runCommand(); m.runCommand()
        XCTAssertEqual(m.runningTasks[p.id]?.count, 1)
        let server = try XCTUnwrap(m.runningTasks[p.id]?.first?.id)
        m.runCommand(command: "printf other; sleep 30")
        let other = try XCTUnwrap(m.runningTasks[p.id]?.last?.id)
        try await waitUntil { CommandRunner.isRunning(taskID: server) && CommandRunner.isRunning(taskID: other) }
        m.stopTask(server)
        XCTAssertTrue(m.runningTasks[p.id]?.first?.isStopping == true)
        try await waitUntil { m.runningTasks[p.id]?.first?.isRunning == false }
        XCTAssertTrue(m.runningTasks[p.id]?.first?.wasStopped == true)
        XCTAssertTrue(CommandRunner.isRunning(taskID: other))
        XCTAssertTrue(m.projects[0].isRunning)
    }
    func testSelectedLogIsNotOverwrittenAndClearDoesNotResurrectOutputAtExit() async throws {
        let (m, p) = model()
        m.runCommand(command: "printf before; sleep 0.4; printf after")
        let first = try XCTUnwrap(m.runningTasks[p.id]?.first?.id)
        try await waitUntil { m.runningTasks[p.id]?.first?.output.contains("before") == true && CommandRunner.isRunning(taskID: first) }
        // Initial command text includes 'before'; wait for the actual stream.
        try await waitUntil { m.runningTasks[p.id]?.first?.output.hasSuffix("before") == true }
        m.clearTaskOutput(first)
        m.runCommand(command: "printf second; sleep 0.1")
        let second = try XCTUnwrap(m.runningTasks[p.id]?.last?.id)
        try await waitUntil { m.runningTasks[p.id]?.allSatisfy { !$0.isRunning } == true }
        XCTAssertEqual(m.runningTasks[p.id]?.first?.output, "after")
        XCTAssertEqual(m.commandOutput, "second")
        m.selectTask(first)
        XCTAssertEqual(m.commandOutput, "after")
        m.removeFinishedTask(first)
        XCTAssertEqual(m.selectedTaskIDs[p.id], second)
    }
    func testRerunPreservesLaunchSnapshotAcrossProjectSwitchAndCanBeCancelled() async throws {
        let (m, p) = model()
        m.runCommand(command: "printf '%s:%s' \"$GW_SNAPSHOT\" \"$PWD\"; sleep 30", workingDirectory: "CodeFlight", environment: ["GW_SNAPSHOT": "retained"])
        let id = try XCTUnwrap(m.runningTasks[p.id]?.first?.id)
        try await waitUntil { CommandRunner.isRunning(taskID: id) }
        m.rerunTask(id)
        let second = Project(name: "other", path: root.path)
        m.projects.append(second); m.selectedProjectID = second.id; m.commandOutput = "other-console"
        try await waitUntil { m.runningTasks[p.id]?.count == 2 }
        let next = try XCTUnwrap(m.runningTasks[p.id]?.last)
        XCTAssertEqual(next.environment["GW_SNAPSHOT"], "retained")
        XCTAssertEqual(next.workingDirectory, root.appendingPathComponent("CodeFlight").path)
        XCTAssertEqual(m.commandOutput, "other-console")
        try await waitUntil { CommandRunner.isRunning(taskID: next.id) }
        m.selectedProjectID = p.id
        m.rerunTask(next.id)
        m.stopCommand()
        try await waitUntil { m.restartingTaskIDs.isEmpty && m.runningTasks[p.id]?.allSatisfy { !$0.isRunning } == true }
        try await Task.sleep(nanoseconds: 1_400_000_000)
        XCTAssertEqual(m.runningTasks[p.id]?.count, 2, "Stop must cancel a queued restart")
        XCTAssertFalse(CommandRunner.hasRunningProcesses(projectID: p.id))
    }

    func testQuitInvalidatesDeferredLaunchesAndQueuedRerunsAcrossProjects() async throws {
        let (m, p) = model()
        m.runCommand(command: "printf ready; sleep 30")
        let id = try XCTUnwrap(m.runningTasks[p.id]?.first?.id)
        try await waitUntil { CommandRunner.isRunning(taskID: id) }
        m.rerunTask(id)
        let other = Project(name: "other", path: root.path)
        m.projects.append(other); m.selectedProjectID = other.id
        // This command is queued on the main actor but has not launched yet.
        m.runCommand(command: "printf must-not-launch; sleep 30")
        let pending = try XCTUnwrap(m.runningTasks[other.id]?.first?.id)
        m.prepareForTermination()
        XCTAssertTrue(m.restartingTaskIDs.isEmpty)
        XCTAssertFalse(CommandRunner.isRunning(taskID: pending))
        m.runCommand(command: "printf forbidden")
        m.rerunTask(id)
        try await waitUntil { m.runningTasks[p.id]?.allSatisfy { !$0.isRunning } == true }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(m.runningTasks[p.id]?.count, 1)
        XCTAssertEqual(m.runningTasks[other.id]?.count, 1)
        XCTAssertFalse(CommandRunner.hasRunningProcesses(projectID: p.id))
        XCTAssertFalse(CommandRunner.hasRunningProcesses(projectID: other.id))
        XCTAssertTrue(m.restartingTaskIDs.isEmpty)
    }

    func testClosingAProjectDuringPendingRerunReleasesSelectionAndDoesNotRestart() async throws {
        let (m, p) = model()
        m.runCommand(command: "printf finished")
        try await waitUntil { m.runningTasks[p.id]?.first?.isRunning == false }
        let id = try XCTUnwrap(m.runningTasks[p.id]?.first?.id)
        m.rerunTask(id)
        // The old session is finished, so closing must cancel the queued launch
        // without displaying a misleading running-process confirmation.
        m.closeProject(p.id)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(m.projects.isEmpty)
        XCTAssertNil(m.runningTasks[p.id])
        XCTAssertNil(m.selectedTaskIDs[p.id])
        XCTAssertTrue(m.restartingTaskIDs.isEmpty)
        XCTAssertFalse(CommandRunner.hasRunningProcesses(projectID: p.id))
    }

    func testCancelledQuitKeepsTheRunAndDraftHandlerAlive() async throws {
        let (m, p) = model()
        m.runCommand(command: "printf ready; sleep 30")
        defer { m.stopCommand() }
        let id = try XCTUnwrap(m.runningTasks[p.id]?.first?.id)
        try await waitUntil { CommandRunner.isRunning(taskID: id) }
        var asked = 0
        m.confirmSheetQuit = { asked += 1; return false }
        m.requestApplicationQuit()
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(m.isTerminating)
        XCTAssertFalse(m.quitRequestPending)
        XCTAssertNotNil(m.confirmSheetQuit)
        XCTAssertTrue(CommandRunner.isRunning(taskID: id))
        XCTAssertTrue(m.runningTasks[p.id]?.first?.isRunning == true)
    }
}
