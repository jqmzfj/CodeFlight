import SwiftUI

struct GitUpstreamSnapshot: Equatable, Sendable {
    let branch: String
    let upstream: String
}

extension GitService {
    static func upstreamSnapshot(at path: String) async -> GitUpstreamSnapshot? {
        let head = await CommandRunner.run(command: "git symbolic-ref -q HEAD", cwd: path)
        let ref = head.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.status == 0, ref.hasPrefix("refs/heads/"), await commitHash(ref, at: path) != nil else { return nil }
        let result = await CommandRunner.run(command: "git for-each-ref --format='%(refname)%00%(upstream)' \(Shell.quote(ref))", cwd: path)
        guard result.status == 0, !result.truncated else { return nil }
        for line in result.output.split(separator: "\n") {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            if fields.count == 2, String(fields[0]) == ref {
                return GitUpstreamSnapshot(branch: String(ref.dropFirst(11)), upstream: String(fields[1]))
            }
        }
        return nil
    }

    static func setUpstream(_ target: String?, snapshot: GitUpstreamSnapshot, at path: String) async -> CommandResult {
        guard await upstreamSnapshot(at: path) == snapshot else {
            return CommandResult(output: "当前分支或跟踪关系已改变，请刷新后重试。 / The current branch or upstream changed. Refresh and retry.", status: 1)
        }
        if let target {
            guard target.hasPrefix("refs/remotes/"), !target.contains("\0"),
                  await CommandRunner.run(command: "git check-ref-format \(Shell.quote(target))", cwd: path).status == 0,
                  await remoteBranches(at: path).contains(String(target.dropFirst(13))),
                  await commitHash(target, at: path) != nil else {
                return CommandResult(output: "所选远程分支已失效，请先 Fetch 或刷新列表。 / The remote branch is unavailable. Fetch or refresh the list.", status: 1)
            }
            return await CommandRunner.run(command: "git branch \(Shell.quote("--set-upstream-to=" + target)) -- \(Shell.quote(snapshot.branch))", cwd: path)
        }
        guard !snapshot.upstream.isEmpty else { return CommandResult(output: "", status: 0) }
        return await CommandRunner.run(command: "git branch --unset-upstream -- \(Shell.quote(snapshot.branch))", cwd: path)
    }
}

struct GitUpstreamSheet: View {
    @ObservedObject var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: GitUpstreamSnapshot?
    @State private var branches: [String] = []
    @State private var selected = ""
    @State private var loading = true
    @State private var submitting = false
    @State private var failure: String?
    @State private var revision = UUID()
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var changed: Bool { snapshot.map { selected != $0.upstream } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(text("设置跟踪分支", "Set Upstream Branch")).font(.headline)
                Spacer()
                Button(text("关闭", "Close")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(submitting)
            }
            if loading { ProgressView().controlSize(.small) }
            else if let snapshot {
                Text(text("当前分支：", "Current branch: ") + snapshot.branch).font(.callout).textSelection(.enabled)
                Picker(text("跟踪分支", "Upstream"), selection: $selected) {
                    Text(text("不跟踪", "No upstream")).tag("")
                    if !snapshot.upstream.isEmpty, !branches.contains(snapshot.upstream) {
                        Text(snapshot.upstream + text("（当前配置）", " (current configuration)")).tag(snapshot.upstream)
                    }
                    ForEach(branches, id: \.self) { ref in Text(String(ref.dropFirst(13))).tag(ref) }
                }.pickerStyle(.menu).disabled(submitting)
                Text(text("仅修改本地分支的跟踪配置。拉取和推送将使用新的上游；文件、提交和远程分支保持不变。", "Updates the local branch tracking configuration used by pull and push. Files, commits and remote branches are preserved.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if branches.isEmpty { Text(text("尚无已获取的远程分支，可关闭窗口后先 Fetch。", "No fetched remote branches. Close this window and Fetch first.")).font(.caption).foregroundStyle(.secondary) }
            } else { Text(text("请切换到已有提交的本地分支后再设置跟踪关系。", "Switch to a local branch with commits before setting its upstream.")).font(.callout) }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled).lineLimit(6) }
            HStack {
                Button(text("刷新", "Refresh")) { revision = UUID() }.disabled(submitting || loading)
                if submitting { ProgressView().controlSize(.small) }
                Spacer()
                Button(text("取消", "Cancel")) { dismiss() }.disabled(submitting)
                Button(text("保存", "Save")) { submit() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!changed || loading || submitting || model.isGitBusy)
            }
        }
        .padding(24)
        .frame(minWidth: 470, idealWidth: 560, maxWidth: .infinity,
               minHeight: 300, idealHeight: 380, maxHeight: .infinity,
               alignment: .topLeading)
        .resizableSheet(minimumWidth: 470, minimumHeight: 300, language: model.language)
        .interactiveDismissDisabled(submitting)
        .task(id: revision) {
            guard let project = model.selectedProject else { return }
            loading = true; failure = nil
            let value = await GitService.upstreamSnapshot(at: project.path)
            let refs = await GitService.remoteBranches(at: project.path)
            guard !Task.isCancelled, model.selectedProjectID == project.id else { return }
            snapshot = value; branches = refs.map { "refs/remotes/" + $0 }; selected = value?.upstream ?? ""; loading = false
        }
        .onChange(of: model.selectedProjectID) { _ in dismiss() }
    }

    private func submit() {
        guard let snapshot, changed, !submitting, !model.isGitBusy else { return }
        submitting = true; failure = nil
        model.setUpstream(selected.isEmpty ? nil : selected, snapshot: snapshot) { result in
            submitting = false
            if result.status == 0 { dismiss() } else { failure = result.output }
        }
    }
}
