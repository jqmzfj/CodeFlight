import XCTest
import Darwin
@testable import CodeFlightApp

final class CommandPipeLifecycleTests: XCTestCase {
    func testFinishDrainsAvailableBytesWithoutWaitingForInheritedWriterEOF() throws {
        let pipe = Pipe()
        let output = OutputAccumulator()
        let reader = CommandPipeReader(handle: pipe.fileHandleForReading, accumulator: output, onOutput: nil)
        try pipe.fileHandleForWriting.write(contentsOf: Data("tail 中文".utf8))
        // Ensure a regression eventually unblocks instead of hanging the suite.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { pipe.fileHandleForWriting.closeFile() }
        let start = Date()
        reader.finish()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.8)
        XCTAssertEqual(output.text(), "tail 中文")
        reader.readAvailable(); reader.finish() // Late callbacks are harmless.
    }

    @MainActor
    func testExitedManagedShellCleansUpInheritedBackgroundProcessBeforeCompleting() async throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = workspace.appendingPathComponent(".pipe-lifecycle-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectID = UUID()
        let start = Date()
        let script = "sleep 8 & echo $! > child.pid; printf parent-done"
        let result = await CommandRunner.run(command: "/bin/sh -c " + Shell.quote(script), cwd: root.path, projectID: projectID, timeoutSeconds: 3)
        let pid = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("child.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertTrue(result.output.contains("parent-done"))
        let state = await CommandRunner.run(command: "ps -o stat= -p \(pid)", cwd: root.path)
        XCTAssertTrue(state.status != 0 || state.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z"), state.output)
        XCTAssertFalse(CommandRunner.hasRunningProcesses(projectID: projectID))
    }
}
