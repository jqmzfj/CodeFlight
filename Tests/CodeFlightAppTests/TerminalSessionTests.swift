import XCTest
import AppKit
import Darwin
@testable import CodeFlightApp

@MainActor
final class TerminalSessionTests: XCTestCase {
    private var root: String { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Terminal did not reach expected state")
    }
    private func output(_ session: WorkbenchTerminalSession) -> String {
        String(decoding: session.view.getBufferAsData(), as: UTF8.self)
    }
    private func send(_ text: String, _ session: WorkbenchTerminalSession) { session.view.send(txt: text) }

    func testRealPTYInteractiveInputWorkingDirectoryAndInterrupt() async throws {
        _ = NSApplication.shared
        let session = WorkbenchTerminalSession(path: root, number: 1)
        defer { session.close() }
        // Split marker literals so the echoed command alone cannot pass tests.
        send("[ -t 0 ] && [ -t 1 ] && printf 'PTY_%s\\n' VERIFIED; pwd\n", session)
        try await waitUntil { self.output(session).contains("PTY_VERIFIED") && self.output(session).contains(self.root) }
        XCTAssertTrue(output(session).contains(root))
        send("read reply; printf 'READ_%s\\n' \"$reply\"\n", session)
        send("成功\n", session)
        try await waitUntil { self.output(session).contains("READ_成功") }
        send("cd /; printf 'CWD_%s\\n' \"$PWD\"\n", session)
        try await waitUntil { self.output(session).contains("CWD_/") }
        send("sleep 30\n", session)
        try await Task.sleep(nanoseconds: 150_000_000)
        send("\u{3}", session)
        send("printf 'INT_%s\\n' OK\n", session)
        try await waitUntil { self.output(session).contains("INT_OK") }
        send("exit\n", session)
        try await waitUntil { session.ended }
    }

    func testLazyProjectIsolationAndCloseCleansForegroundJob() async throws {
        _ = NSApplication.shared
        let store = WorkbenchTerminals()
        let first = Project(name: "terminal-qa", path: root)
        let second = Project(name: "terminal-qa-2", path: root)
        XCTAssertFalse(store.hasSessions)
        store.add(project: first); store.add(project: first); store.add(project: second)
        defer { store.closeAll() }
        let one = try XCTUnwrap(store.sessions[first.id]?.first)
        let two = try XCTUnwrap(store.sessions[first.id]?.last)
        let other = try XCTUnwrap(store.sessions[second.id]?.first)
        XCTAssertNotEqual(one.id, two.id)
        send("export GW_TERMINAL_QA=one; /bin/sh -c 'trap \"\" HUP TERM; printf \"JOB_%s\\n\" READY; while :; do sleep 1; done'\n", one)
        send("printf 'ISOLATION_%s\\n' \"${GW_TERMINAL_QA:-empty}\"\n", two)
        try await waitUntil { self.output(two).contains("ISOLATION_empty") }
        try await waitUntil { self.output(one).contains("JOB_READY") }
        XCTAssertTrue(one.hasRunningCommands)
        XCTAssertFalse(two.hasRunningCommands)
        let fg = tcgetpgrp(one.view.process.childfd)
        XCTAssertGreaterThan(fg, 1)
        store.closeProject(first.id)
        try await waitUntil { one.ended && two.ended }
        try await waitUntil { kill(-fg, 0) != 0 }
        XCTAssertTrue(other.view.process.running)
        XCTAssertNil(store.sessions[first.id])
        XCTAssertEqual(store.sessions[second.id]?.count, 1)
        store.closeAll()
        XCTAssertTrue(store.hasSessions, "Quit must wait for cleanup after the last tab has disappeared")
        try await waitUntil { !store.hasSessions }
    }

    func testClosingLastProjectRetainsQuitGateUntilResistantJobIsKilled() async throws {
        _ = NSApplication.shared
        let store = WorkbenchTerminals()
        let project = Project(name: "terminal-quit-qa", path: root)
        store.add(project: project)
        defer { store.closeAll() }
        let session = try XCTUnwrap(store.sessions[project.id]?.first)
        send("/bin/sh -c 'trap \"\" HUP TERM; printf \"READY_%s\\n\" TO_CLOSE; while :; do sleep 1; done'\n", session)
        try await waitUntil { self.output(session).contains("READY_TO_CLOSE") }
        let foreground = tcgetpgrp(session.view.process.childfd)
        XCTAssertGreaterThan(foreground, 1)
        store.closeProject(project.id)
        XCTAssertNil(store.sessions[project.id])
        XCTAssertTrue(store.hasSessions)
        try await waitUntil { !store.hasSessions }
        try await waitUntil { kill(-foreground, 0) != 0 }
    }

    func testInvalidShellFallsBack() {
        XCTAssertEqual(WorkbenchTerminalSession.shell(environment: ["SHELL": "/does-not-exist"]), "/bin/zsh")
        XCTAssertEqual(WorkbenchTerminalSession.shell(environment: ["SHELL": "/bin/bash"]), "/bin/bash")
    }

    func testFocusKeepsSelectedSessionAndNewSessionIsExplicit() async throws {
        _ = NSApplication.shared
        let model = WorkbenchModel(restoringSession: false)
        let project = Project(name: "terminal-focus-qa", path: root)
        model.projects = [project]; model.selectedProjectID = project.id
        defer { model.terminals.closeAll() }
        model.focusTerminal()
        let first = try XCTUnwrap(model.terminals.selection[project.id])
        let request = model.terminalFocusRequest
        model.focusTerminal()
        XCTAssertEqual(model.terminals.sessions[project.id]?.count, 1)
        XCTAssertEqual(model.terminals.selection[project.id], first)
        XCTAssertNotEqual(model.terminalFocusRequest, request)
        model.focusTerminal(newSession: true)
        XCTAssertEqual(model.terminals.sessions[project.id]?.count, 2)
        XCTAssertNotEqual(model.terminals.selection[project.id], first)
        model.terminals.selection[project.id] = first
        model.focusTerminal()
        XCTAssertEqual(model.terminals.selection[project.id], first)
        model.terminals.closeAll()
        try await waitUntil { !model.terminals.hasSessions }
    }
}
