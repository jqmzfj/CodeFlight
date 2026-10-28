import XCTest
@testable import CodeFlightApp

@MainActor
final class ServicesInteractionTests: XCTestCase {
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Service operation did not finish")
    }
    private var container: DockerContainer { DockerContainer(id: "abcdef123456", name: "fixture", image: "fixture:1", status: "Up 1 minute", ports: "127.0.0.1:8080->80/tcp") }
    func testDockerResponsesDistinguishEmptyUnavailableAndInvalidResults() async {
        XCTAssertNil(DockerService.parse(CommandResult(output: "", status: 0)).error)
        XCTAssertNotNil(DockerService.parse(CommandResult(output: "Cannot connect to the Docker daemon", status: 1)).error)
        let parsed = DockerService.parse(CommandResult(output: "abcdef123456|fixture|fixture:1|Up 1 minute|127.0.0.1:8080->80/tcp\n", status: 0))
        XCTAssertNil(parsed.error); XCTAssertEqual(parsed.containers.count, 1)
        XCTAssertTrue(parsed.containers[0].isRunning)
        XCTAssertNotNil(DockerService.parse(CommandResult(output: "shell startup warning\n", status: 0)).error)
        XCTAssertNotNil(DockerService.parse(CommandResult(output: "", status: 0, truncated: true)).error)
        XCTAssertNotNil(DockerService.parse(CommandResult(output: "abcdef123456|a|b|Exited|\nabcdef123456|a|b|Exited|", status: 0)).error)
        let invalid = await DockerService.perform(.start, container: "$(touch should-not-exist)")
        XCTAssertNotEqual(invalid.status, 0)
    }
    func testRefreshFailureKeepsCachedContainersAndRetryCanReturnEmptySuccess() async throws {
        let m = WorkbenchModel(restoringSession: false)
        m.dockerContainers = [container]
        var reads = 0
        m.dockerClient = DockerClient(list: {
            reads += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
            return reads == 1 ? DockerSnapshot(error: "daemon stopped") : DockerSnapshot()
        }, perform: { _, _ in XCTFail("Refresh must not execute actions"); return CommandResult(output: "", status: 1) })
        m.refreshDocker(); m.refreshDocker()
        XCTAssertTrue(m.isDockerLoading)
        try await waitUntil { !m.isDockerLoading }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(m.dockerContainers.count, 1)
        XCTAssertEqual(m.dockerError, "daemon stopped")
        m.refreshDocker()
        try await waitUntil { !m.isDockerLoading }
        XCTAssertTrue(m.dockerContainers.isEmpty)
        XCTAssertNil(m.dockerError)
    }
    func testContainerActionIsSerializedRetryClearsFailureAndLeavesConsoleUntouched() async throws {
        let m = WorkbenchModel(restoringSession: false); let fixture = container
        m.dockerContainers = [fixture]; m.commandOutput = "selected run log"
        var actions = 0; var reads = 0
        m.dockerClient = DockerClient(list: { reads += 1; return DockerSnapshot(containers: [fixture]) }, perform: { _, id in
            XCTAssertEqual(id, fixture.id); actions += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
            return CommandResult(output: actions == 1 ? "permission denied" : "done", status: actions == 1 ? 1 : 0)
        })
        m.dockerAction(.stop, container: fixture); m.dockerAction(.restart, container: fixture); m.refreshDocker()
        XCTAssertEqual(m.dockerBusyContainer, fixture.id)
        try await waitUntil { m.dockerBusyContainer == nil }
        XCTAssertEqual(actions, 1); XCTAssertEqual(reads, 1)
        XCTAssertTrue(m.dockerActionErrors[fixture.id]?.contains("permission denied") == true)
        m.dockerAction(.stop, container: fixture)
        try await waitUntil { m.dockerBusyContainer == nil }
        XCTAssertEqual(actions, 2); XCTAssertNil(m.dockerActionErrors[fixture.id])
        XCTAssertNotNil(m.dockerNotice)
        XCTAssertEqual(m.commandOutput, "selected run log")
    }
}
