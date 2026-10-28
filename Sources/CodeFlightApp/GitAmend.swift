import SwiftUI

struct GitAmendSnapshot: Sendable {
    let hash: String
    let message: String
}

extension GitService {
    static func amendSnapshot(at path: String) async -> GitAmendSnapshot? {
        let result = await CommandRunner.run(command: "git log -1 --format='%H%x00%B' HEAD --", cwd: path)
        guard result.status == 0, !result.truncated, let separator = result.output.firstIndex(of: "\0") else { return nil }
        return GitAmendSnapshot(hash: String(result.output[..<separator]), message: String(result.output[result.output.index(after: separator)...]).trimmingCharacters(in: .newlines))
    }

    static func amend(message: String, expectedHEAD: String, includeStaged: Bool, at path: String) async -> CommandResult {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !message.contains("\0") else {
            return CommandResult(output: "请填写提交说明。 / Enter a commit message.", status: 1)
        }
        guard let snapshot = await amendSnapshot(at: path), snapshot.hash == expectedHEAD else {
            return CommandResult(output: "最近提交已改变，请关闭窗口并重新打开。 / HEAD changed. Reopen the amend window.", status: 1)
        }
        guard await operationState(at: path) == nil else {
            return CommandResult(output: "请先完成或中止当前 Git 操作。 / Finish or abort the current Git operation first.", status: 1)
        }
        let status = await status(at: path)
        guard status.isRepository, status.error == nil, !status.changes.contains(where: \.isConflicted) else {
            return CommandResult(output: status.error ?? "请先解决冲突。 / Resolve conflicts first.", status: 1)
        }
        return await CommandRunner.run(command: "git commit --amend \(includeStaged ? "" : "--only ")-m \(Shell.quote(message))", cwd: path)
    }
}

struct GitAmendSheet: View {
    @ObservedObject var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: GitAmendSnapshot?
    @State private var message = ""
    @State private var includeStaged = true
    @State private var loading = true
    @State private var failure: String?
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(text("修改最近一次提交", "Amend Last Commit")).font(.system(size: 14, weight: .semibold))
                Spacer()
                if loading || model.isGitBusy { ProgressView().controlSize(.small) }
                Button(text("关闭", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let snapshot {
                Text(String(snapshot.hash.prefix(8))).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                TextEditor(text: $message).font(.system(size: 12)).frame(minHeight: 120)
                    .padding(5).overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.12)))
                    .accessibilityLabel(text("提交说明", "Commit message"))
                    .disabled(model.isGitBusy)
                Toggle(text("包含已暂存的修改", "Include staged changes"), isOn: $includeStaged)
                    .disabled(model.isGitBusy)
                Text(includeStaged ? text("补入当前暂存区的内容，未暂存修改保留。", "Include the current index; keep unstaged changes.") : text("只修改提交说明，暂存区和工作区内容保留。", "Change only the message; keep the index and working tree.")).font(.caption).foregroundStyle(.secondary)
                Label(text("这会改写最近提交的历史。已经推送的提交，请先与协作者确认。", "This rewrites the last commit. Coordinate before amending a published commit."), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled).lineLimit(5) }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(text("取消", "Cancel")) { dismiss() }
                Button(text("修改提交", "Amend Commit")) {
                    guard let snapshot else { return }
                    model.amendLastCommit(message: message, snapshot: snapshot, includeStaged: includeStaged) { result in
                        if result.status == 0 { dismiss() } else { failure = result.output }
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(loading || model.isGitBusy || snapshot == nil || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 540, idealWidth: 600, maxWidth: .infinity,
               minHeight: 390, idealHeight: 460, maxHeight: .infinity,
               alignment: .topLeading)
        .resizableSheet(minimumWidth: 540, minimumHeight: 390, language: model.language)
            .task {
                guard let project = model.selectedProject else { loading = false; return }
                let value = await GitService.amendSnapshot(at: project.path)
                guard !Task.isCancelled else { return }
                snapshot = value; message = value?.message ?? ""; loading = false
                if value == nil { failure = text("当前仓库没有可修改的提交，或提交说明过大。", "No commit to amend, or the commit message is too large.") }
            }
            .onChange(of: model.selectedProjectID) { _ in dismiss() }
    }
}
