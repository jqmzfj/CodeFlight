import Foundation

/// A cancelled read owns exactly one command ID. Other Git operations and run
/// sessions keep their own lifetimes; cancellation never calls stopAll().
enum CancellableGitRead {
    @MainActor
    static func run(command: String, cwd: String, outputLimit: Int = 256 * 1024, taskID: UUID = UUID(), timeoutSeconds: Double? = nil) async -> CommandResult {
        let cancelled = CommandResult(output: "读取已取消。 / Read cancelled.", status: 130)
        guard !Task.isCancelled else { return cancelled }
        let id = taskID
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return cancelled }
            return await CommandRunner.run(command: command, cwd: cwd, taskID: id, outputLimit: outputLimit, timeoutSeconds: timeoutSeconds)
        } onCancel: {
            Task { @MainActor in CommandRunner.stop(taskID: id) }
        }
    }
}
