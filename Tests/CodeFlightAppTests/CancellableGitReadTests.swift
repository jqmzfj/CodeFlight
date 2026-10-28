import XCTest
import Darwin
@testable import CodeFlightApp

final class CancellableGitReadTests: XCTestCase {
    @MainActor
    func testCancellationStopsOwnedProcessWithoutStoppingAnotherRead() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".git-read-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = "echo $$ > owned.pid; sleep 20 & echo $! > child.pid; wait"
        let owned = Task { await CancellableGitRead.run(command: "/bin/sh -c " + Shell.quote(script), cwd: root.path) }
        let survivor = Task { await CancellableGitRead.run(command: "sleep 1; printf survivor", cwd: root.path) }
        defer { owned.cancel(); survivor.cancel() }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("child.pid").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("child.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let start = Date()
        owned.cancel()
        let result = await owned.value
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 4, "Cancellation must not wait for the 20-second read")
        let other = await survivor.value
        XCTAssertEqual(other.status, 0); XCTAssertEqual(other.output, "survivor")
        let state = await CommandRunner.run(command: "ps -o stat= -p \(pid)", cwd: root.path)
        XCTAssertTrue(state.status != 0 || state.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z"), state.output)
    }

    @MainActor
    func testAlreadyCancelledReadDoesNotLaunchAProcess() async throws {
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await CancellableGitRead.run(command: "printf should-not-run", cwd: FileManager.default.currentDirectoryPath)
        }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.status, 130)
        XCTAssertFalse(result.output.contains("should-not-run"))
    }

    @MainActor func testExplicitOwnerCanBeStoppedAndReadTimeoutIsPreserved() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".git-read-owner-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let owned = Task { await CancellableGitRead.run(command: "printf ready > ready; sleep 20", cwd: root.path, taskID: id) }
        defer { owned.cancel() }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("ready").path))
        let start = Date()
        CommandRunner.stop(taskID: id)
        let stopped = await owned.value
        XCTAssertNotEqual(stopped.status, 0); XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        let timeoutStart = Date()
        let timedOut = await CancellableGitRead.run(command: "sleep 20", cwd: root.path, timeoutSeconds: 0.2)
        XCTAssertNotEqual(timedOut.status, 0); XCTAssertLessThan(Date().timeIntervalSince(timeoutStart), 4)
    }

}
