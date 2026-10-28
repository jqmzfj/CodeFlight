import XCTest
@testable import CodeFlightApp

final class CommandOutputCompletionTests: XCTestCase {
    @MainActor
    func testConcurrentShortCommandsReturnAllStdoutAndStderrBeforeCompletion() async {
        let cwd = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
        await withTaskGroup(of: (Int, CommandResult).self) { group in
            for index in 0..<60 {
                group.addTask {
                    let result = await CommandRunner.run(command: "printf 'out-\(index)'; printf 'err-\(index)' >&2", cwd: cwd)
                    return (index, result)
                }
            }
            for await (index, result) in group {
                XCTAssertEqual(result.status, 0, result.output)
                XCTAssertEqual(result.output, "out-\(index)err-\(index)")
                XCTAssertFalse(result.truncated)
            }
        }
    }
}
