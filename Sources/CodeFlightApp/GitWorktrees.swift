import SwiftUI
import AppKit

struct GitWorktree: Identifiable, Sendable, Equatable {
    let path: String
    let hash: String
    let branch: String
    let primary: Bool
    let bare: Bool
    let locked: String?
    let prunable: String?
    var id: String { path }
    var branchLabel: String { branch.hasPrefix("refs/heads/") ? String(branch.dropFirst(11)) : "HEAD (detached)" }
}

enum GitWorktreeMode: String, CaseIterable, Identifiable {
    case newBranch, existingBranch, detached
    var id: String { rawValue }
}

extension GitService {
    static func moveWorktree(_ tree: GitWorktree, destination: String, at path: String) async -> CommandResult {
        guard destination.hasPrefix("/"), !destination.contains("\0") else {
            return CommandResult(output: "请选择新工作目录的绝对路径。 / Choose an absolute destination path.", status: 1)
        }
        let result = await worktrees(at: path)
        guard result.1 == nil, let current = result.0.first(where: { $0.path == tree.path }), current == tree,
              !current.primary, !current.bare, current.locked == nil, current.prunable == nil else {
            return CommandResult(output: "工作树状态已改变、已锁定或不支持移动，请刷新。 / Worktree changed, is locked, or cannot be moved. Refresh the list.", status: 1)
        }
        let source = URL(fileURLWithPath: current.path).resolvingSymlinksInPath().standardizedFileURL.path
        let targetURL = URL(fileURLWithPath: destination).standardizedFileURL
        let target = targetURL.resolvingSymlinksInPath().path
        let cwd = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let common = await CommandRunner.run(command: "git rev-parse --path-format=absolute --git-common-dir", cwd: path)
        guard common.status == 0, !common.truncated else { return CommandResult(output: common.output, status: 1) }
        let metadata = URL(fileURLWithPath: common.output.trimmingCharacters(in: .newlines)).resolvingSymlinksInPath().standardizedFileURL.path
        let manager = FileManager.default
        // Existing directories have a different meaning to `git worktree move`:
        // Git appends the source basename. Require one exact, new destination.
        guard !manager.fileExists(atPath: targetURL.path),
              (try? manager.attributesOfItem(atPath: targetURL.path)) == nil,
              manager.fileExists(atPath: targetURL.deletingLastPathComponent().path),
              target != source, !target.hasPrefix(source + "/"),
              target != metadata, !target.hasPrefix(metadata + "/"),
              cwd != source, !cwd.hasPrefix(source + "/") else {
            return CommandResult(output: "目标必须是已有父目录下的新目录，且不能位于原目录或 Git 数据目录内。请从其他工作树发起移动。 / Choose a new directory with an existing parent outside the source and Git metadata, and run from another worktree.", status: 1)
        }
        return await CommandRunner.run(command: "git worktree move -- \(Shell.quote(current.path)) \(Shell.quote(targetURL.path))", cwd: path)
    }

    static func setWorktreeLocked(_ tree: GitWorktree, locked: Bool, reason: String, at path: String) async -> CommandResult {
        guard !reason.contains("\0"), reason.utf8.count <= 4096 else {
            return CommandResult(output: "锁定说明过长或包含无效字符。 / Invalid or oversized lock reason.", status: 1)
        }
        let result = await worktrees(at: path)
        guard result.1 == nil, let current = result.0.first(where: { $0.path == tree.path }),
              current == tree, !current.primary, !current.bare,
              locked ? current.locked == nil : current.locked != nil else {
            return CommandResult(output: "工作树状态已改变或不支持此操作，请刷新后重试。 / Worktree changed or does not support this action. Refresh and retry.", status: 1)
        }
        let action = locked ? "lock --reason \(Shell.quote(reason))" : "unlock"
        return await CommandRunner.run(command: "git worktree \(action) -- \(Shell.quote(current.path))", cwd: path)
    }

    static func pruneWorktrees(expected: [GitWorktree], at path: String) async -> CommandResult {
        let result = await worktrees(at: path)
        guard result.1 == nil, result.0 == expected else {
            return CommandResult(output: "工作树列表已改变，请刷新并重新确认。 / Worktree list changed. Refresh and confirm again.", status: 1)
        }
        let candidates = expected.filter { !$0.primary && $0.locked == nil && $0.prunable != nil }
        guard !candidates.isEmpty, candidates.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
            return CommandResult(output: "没有可清理的失效记录，或目录已恢复，请刷新。 / No stale records, or a directory has returned. Refresh the list.", status: 1)
        }
        // Prune only metadata for missing, unlocked checkouts; never delete working directories.
        return await CommandRunner.run(command: "git worktree prune --verbose --expire now", cwd: path)
    }

    static func worktrees(at path: String) async -> ([GitWorktree], String?) {
        let result = await CommandRunner.run(command: "git worktree list --porcelain -z", cwd: path, outputLimit: 1024 * 1024)
        guard result.status == 0, !result.truncated else { return ([], result.truncated ? "工作树列表超过读取限制。 / Worktree list exceeds the read limit." : result.output) }
        var entries: [GitWorktree] = [], fields: [String: String] = [:]
        func append() {
            guard let location = fields["worktree"] else { return }
            entries.append(GitWorktree(path: location, hash: fields["HEAD"] ?? "", branch: fields["branch"] ?? "", primary: entries.isEmpty, bare: fields["bare"] != nil, locked: fields["locked"], prunable: fields["prunable"]))
            fields = [:]
        }
        for record in result.output.components(separatedBy: "\0") {
            if record.isEmpty { append(); continue }
            let pair = record.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            fields[String(pair[0])] = pair.count == 2 ? String(pair[1]) : ""
        }
        append()
        return (entries, nil)
    }

    static func addWorktree(destination: String, mode: GitWorktreeMode, branch: String, target: String, at path: String) async -> CommandResult {
        guard destination.hasPrefix("/"), !destination.contains("\0") else { return CommandResult(output: "请选择工作树的绝对路径。 / Choose an absolute worktree path.", status: 1) }
        var arguments: String
        switch mode {
        case .newBranch:
            guard !branch.isEmpty, !branch.hasPrefix("-"), await CommandRunner.run(command: "git check-ref-format \(Shell.quote("refs/heads/" + branch))", cwd: path).status == 0,
                  let hash = await commitHash(target, at: path) else { return CommandResult(output: "请输入有效的新分支名称和起点。 / Enter a valid new branch and starting commit.", status: 1) }
            arguments = "-b \(Shell.quote(branch)) -- \(Shell.quote(destination)) \(hash)"
        case .existingBranch:
            guard !branch.isEmpty, !branch.hasPrefix("-"), await CommandRunner.run(command: "git show-ref --verify --quiet \(Shell.quote("refs/heads/" + branch))", cwd: path).status == 0 else { return CommandResult(output: "请选择现有本地分支。 / Choose an existing local branch.", status: 1) }
            arguments = "-- \(Shell.quote(destination)) \(Shell.quote(branch))"
        case .detached:
            guard let hash = await commitHash(target, at: path) else { return CommandResult(output: "起点不是有效提交。 / Starting point is not a valid commit.", status: 1) }
            arguments = "--detach -- \(Shell.quote(destination)) \(hash)"
        }
        return await CommandRunner.run(command: "git worktree add \(arguments)", cwd: path)
    }

    static func removeWorktree(_ tree: GitWorktree, at path: String) async -> CommandResult {
        let result = await worktrees(at: path)
        guard result.1 == nil, let current = result.0.first(where: { $0.path == tree.path }),
              !current.primary, !current.bare, current.locked == nil,
              current.hash == tree.hash, current.branch == tree.branch else {
            return CommandResult(output: "工作树已改变、被锁定或是主工作树，请刷新后重试。 / Worktree changed, is locked, or is the primary worktree. Refresh and retry.", status: 1)
        }
        // Never use --force: Git checks tracked/untracked changes and submodules.
        return await CommandRunner.run(command: "git worktree remove -- \(Shell.quote(current.path))", cwd: path)
    }
}

struct GitWorktreesSheet: View {
    @ObservedObject var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draftGuard = SheetDraftGuard()
    @State private var trees: [GitWorktree] = []
    @State private var selection: String?
    @State private var loading = true
    @State private var failure: String?
    @State private var mode = GitWorktreeMode.newBranch
    @State private var branch = ""
    @State private var existingBranch = ""
    @State private var target = "HEAD"
    @State private var destination = ""
    @State private var revision = UUID()
    @State private var lockReason = ""
    @State private var confirmingPrune = false
    @State private var feedback: String?
    @State private var moving = false
    @State private var moveDestination = ""
    private var detailDirty: Bool { !lockReason.isEmpty || (moving && !moveDestination.isEmpty) }
    private var dirty: Bool { detailDirty || !branch.isEmpty || target != "HEAD" || !destination.isEmpty || mode != .newBranch }
    private var selectionBinding: Binding<String?> {
        Binding(get: { selection }, set: { value in selectTree(value) })
    }
    private var selected: GitWorktree? { trees.first { $0.id == selection } }
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private func isOpen(_ tree: GitWorktree) -> Bool {
        let root = URL(fileURLWithPath: tree.path).resolvingSymlinksInPath().standardizedFileURL.path
        return model.projects.contains {
            let project = URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path
            return project == root || project.hasPrefix(root + "/")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(text("工作树", "Worktrees"), systemImage: "square.stack.3d.up").font(.headline)
                if dirty { Text(text("未保存", "Unsaved")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if loading || model.isGitBusy { ProgressView().controlSize(.small) }
                Button { draftGuard.request(dirty: detailDirty) { lockReason = ""; moving = false; moveDestination = ""; revision = UUID() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).accessibilityLabel(text("刷新工作树", "Refresh worktrees")).help(text("刷新工作树", "Refresh worktrees")).disabled(loading || model.isGitBusy)
                Button(text("关闭", "Close")) { draftGuard.request(dirty: dirty) { dismiss() } }.keyboardShortcut(.cancelAction).disabled(model.isGitBusy)
            }.padding(16)
            Divider()
            WorkbenchSplit("worktrees", initial: 230, minimum: 180, otherMinimum: 440) {
                VStack(spacing: 0) {
                    List(trees, selection: selectionBinding) { tree in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(URL(fileURLWithPath: tree.path).lastPathComponent, systemImage: tree.primary ? "house" : "folder").font(.system(size: 12)).lineLimit(1)
                            Text(tree.bare ? "bare" : tree.branchLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.padding(.vertical, 4).tag(tree.id).help(tree.path)
                    }.listStyle(.sidebar).disabled(loading || model.isGitBusy)
                    Divider()
                    HStack {
                        Button { selectTree(nil) } label: { Image(systemName: "plus") }.accessibilityLabel(text("新建工作树", "Add worktree")).help(text("新建工作树", "Add worktree"))
                        Spacer()
                        Button { draftGuard.request(dirty: detailDirty) { lockReason = ""; moveDestination = ""; confirmingPrune = true; moving = false; failure = nil; feedback = nil } } label: { Image(systemName: "trash") }
                            .accessibilityLabel(text("清理失效记录", "Prune stale records")).help(text("清理失效记录", "Prune stale records"))
                            .disabled(!trees.contains { !$0.primary && $0.locked == nil && $0.prunable != nil })
                    }.buttonStyle(.borderless).padding(10)
                        .disabled(loading || model.isGitBusy)
                }.frame(maxWidth: .infinity)
                } second: {
                ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if confirmingPrune {
                            Text(text("清理失效工作树记录", "Prune stale worktree records")).font(.headline)
                            Text(text("仅清理以下已不存在目录的 Git 登记，不删除工作目录或分支。暂时断开的磁盘请先取消并锁定对应工作树。", "Removes Git registrations for missing directories, keeping branches. For disconnected disks, cancel and lock the worktree first.")).font(.caption).foregroundStyle(.secondary)
                            ForEach(trees.filter { !$0.primary && $0.locked == nil && $0.prunable != nil }) { tree in
                                Text(tree.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            }
                            HStack {
                                Button(text("取消", "Cancel")) { confirmingPrune = false }
                                Button(text("确认清理", "Prune"), role: .destructive) {
                                    model.pruneWorktrees(trees) { result in finish(result, message: text("已清理失效记录。", "Stale records pruned.")) }
                                }
                            }.disabled(model.isGitBusy)
                        } else if let selected { details(selected) } else { createForm }
                        if let failure {
                            Text(failure).font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.orange).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                                .id("failure")
                        }
                        if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).id("content")
                }
                .onChange(of: failure) { value in
                    guard value != nil else { return }
                    DispatchQueue.main.async { proxy.scrollTo("failure", anchor: .top) }
                }
                .onChange(of: selection) { _ in proxy.scrollTo("content", anchor: .top) }
                }.frame(minWidth: 440, maxWidth: .infinity)
            }
        }.frame(minWidth: 680, idealWidth: 800, maxWidth: .infinity, minHeight: 400, idealHeight: 530, maxHeight: .infinity)
        .resizableSheet(minimumWidth: 680, minimumHeight: 400, language: model.language)
        .protectDraft(using: draftGuard, model: model, dirty: { dirty }, busy: { model.isGitBusy }, context: {
            text("正在编辑的工作树信息尚未应用。你可以继续编辑，或放弃输入后继续操作。", "The worktree edits have not been applied. Keep editing or discard the input to continue.")
        })
        .task(id: revision) {
            guard let project = model.selectedProject else { loading = false; return }
            loading = true
            let result = await GitService.worktrees(at: project.path)
            guard !Task.isCancelled, model.selectedProjectID == project.id else { return }
            trees = result.0; failure = result.1; loading = false
            if let selection, !trees.contains(where: { $0.id == selection }) { self.selection = nil }
        }
        .onAppear { existingBranch = model.gitBranches.first ?? "" }
        .onChange(of: selection) { _ in lockReason = ""; confirmingPrune = false; moving = false; moveDestination = "" }
        .onChange(of: model.selectedProjectID) { _ in dismiss() }
    }

    private func selectTree(_ value: String?) {
        guard value != selection else { confirmingPrune = false; failure = nil; feedback = nil; return }
        draftGuard.request(dirty: detailDirty) { selection = value; failure = nil; feedback = nil }
    }

    private func finish(_ result: CommandResult, message: String) {
        failure = result.status == 0 ? nil : result.output
        if result.status == 0 { feedback = message; confirmingPrune = false; revision = UUID() }
    }

    private func details(_ tree: GitWorktree) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tree.primary ? text("主工作树", "Primary worktree") : text("关联工作树", "Linked worktree")).font(.headline)
            Text(tree.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            Text(tree.bare ? "bare" : tree.branchLabel).font(.callout)
            Text(tree.hash).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if let reason = tree.locked { Label(text("已锁定", "Locked") + (reason.isEmpty ? "" : ": " + reason), systemImage: "lock").font(.caption) }
            if let reason = tree.prunable { Text(text("路径可能已移除：", "Path may have been removed: ") + reason).font(.caption).foregroundStyle(.orange) }
            Button(text("作为项目打开", "Open as project")) {
                draftGuard.request(dirty: dirty) { model.confirmSheetQuit = nil; dismiss(); model.openProject(at: URL(fileURLWithPath: tree.path)) }
            }.disabled(tree.bare || !FileManager.default.fileExists(atPath: tree.path))
            Divider()
            if !tree.primary && !tree.bare {
                if tree.locked == nil {
                    TextField(text("锁定说明（可选）", "Lock reason (optional)"), text: $lockReason).textFieldStyle(.roundedBorder).accessibilityLabel(text("锁定说明（可选）", "Lock reason (optional)"))
                    Text(text("锁定可防止工作树被移动、移除或清理，适用于临时断开的磁盘。", "Locking prevents moving, removal and pruning, including while a disk is disconnected.")).font(.caption).foregroundStyle(.secondary)
                    Button(text("锁定工作树", "Lock worktree")) {
                        model.setWorktreeLocked(tree, locked: true, reason: lockReason) { result in if result.status == 0 { lockReason = "" }; finish(result, message: text("工作树已锁定。", "Worktree locked.")) }
                    }
                } else {
                    Button(text("解锁工作树", "Unlock worktree")) {
                        model.setWorktreeLocked(tree, locked: false, reason: "") { result in finish(result, message: text("工作树已解锁。", "Worktree unlocked.")) }
                    }
                }
                Divider()
            }
            if tree.primary { Text(text("主工作树不能在此移除。", "The primary worktree cannot be removed here.")).font(.caption).foregroundStyle(.secondary) }
            else if isOpen(tree) { Text(text("此工作树已在项目标签中打开，关闭该项目后再移动或移除。", "This worktree is open in a project tab. Close it before moving or removal.")).font(.caption).foregroundStyle(.secondary) }
            else {
                if moving {
                    Text(text("移动工作树", "Move worktree")).font(.headline)
                    HStack {
                        TextField(text("新目录的绝对路径", "Absolute destination path"), text: $moveDestination).textFieldStyle(.roundedBorder).accessibilityLabel(text("新目录的绝对路径", "Absolute destination path"))
                        Button(text("选择…", "Choose…")) {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                            panel.prompt = text("选择父目录", "Choose parent")
                            if panel.runModal() == .OK, let url = panel.url { moveDestination = url.appendingPathComponent(URL(fileURLWithPath: tree.path).lastPathComponent).path }
                        }
                    }
                    Text(text("将完整目录及本地修改一起移动，Git 自动更新登记。目标目录必须尚不存在；移动失败保留输入。", "Moves the whole directory and local changes, updating Git registration. The destination must not exist. Input is kept on failure.")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(text("取消", "Cancel")) { moving = false; moveDestination = ""; failure = nil }
                        Button(text("确认移动", "Move")) {
                            let location = (moveDestination.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
                            model.moveWorktree(tree, destination: location) { result in
                                if result.status == 0 { selection = URL(fileURLWithPath: location).resolvingSymlinksInPath().standardizedFileURL.path; moving = false; moveDestination = "" }
                                finish(result, message: text("工作树已移动。", "Worktree moved."))
                            }
                        }.disabled(moveDestination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    Button(text("移动工作树…", "Move worktree…")) { moving = true; failure = nil; feedback = nil }
                        .disabled(tree.locked != nil || tree.prunable != nil)
                }
                Divider()
                Text(text("移除会删除此工作目录，分支仍会保留。有未提交内容或锁定状态时 Git 会拒绝操作。", "Removal deletes this working directory and keeps the branch. Git refuses if changes or a lock are present.")).font(.caption).foregroundStyle(.secondary)
                Button(text("移除工作树…", "Remove worktree…"), role: .destructive) {
                    model.removeWorktree(tree) { result in failure = result.status == 0 ? nil : result.output; if result.status == 0 { selection = nil; revision = UUID() } }
                }.disabled(model.isGitBusy || tree.locked != nil)
            }
        }.disabled(model.isGitBusy || loading)
    }

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("新建工作树", "Add worktree")).font(.headline)
            Text(text("共享 Git 对象，每个目录拥有独立工作区，可同时打开不同分支。", "Shares Git objects with an independent working directory for each branch.")).font(.caption).foregroundStyle(.secondary)
            Picker(text("方式", "Mode"), selection: $mode) {
                Text(text("新建分支", "New branch")).tag(GitWorktreeMode.newBranch)
                Text(text("现有分支", "Existing branch")).tag(GitWorktreeMode.existingBranch)
                Text(text("分离 HEAD", "Detached HEAD")).tag(GitWorktreeMode.detached)
            }.pickerStyle(.segmented).labelsHidden()
            if mode == .existingBranch {
                Picker(text("分支", "Branch"), selection: $existingBranch) { ForEach(model.gitBranches, id: \.self) { Text($0).tag($0) } }
                Text(text("已在其他工作树打开的分支不能再次检出。", "A branch checked out in another worktree cannot be checked out again.")).font(.caption).foregroundStyle(.secondary)
            } else {
                if mode == .newBranch { TextField(text("新分支名称", "New branch name"), text: $branch).textFieldStyle(.roundedBorder).accessibilityLabel(text("新分支名称", "New branch name")) }
                TextField(text("起点提交或分支", "Starting commit or branch"), text: $target).textFieldStyle(.roundedBorder).accessibilityLabel(text("起点提交或分支", "Starting commit or branch"))
            }
            Text(text("新工作目录", "New working directory")).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField(text("绝对路径", "Absolute path"), text: $destination).textFieldStyle(.roundedBorder).accessibilityLabel(text("绝对路径", "Absolute path"))
                Button(text("选择…", "Choose…")) {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.prompt = text("选择父目录", "Choose parent")
                    if panel.runModal() == .OK, let url = panel.url {
                        let folder = branch.isEmpty ? "worktree" : branch.replacingOccurrences(of: "/", with: "-")
                        destination = url.appendingPathComponent(folder).path
                    }
                }
            }
            Text(text("在所选目录中创建新文件夹；不覆盖已有的非空目录。", "Creates a new folder in the selected location; existing nonempty directories are kept.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(text("创建", "Create")) {
                    let location = (destination.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
                    model.addWorktree(destination: location, mode: mode, branch: mode == .existingBranch ? existingBranch : branch.trimmingCharacters(in: .whitespacesAndNewlines), target: target.trimmingCharacters(in: .whitespacesAndNewlines)) { result in
                        failure = result.status == 0 ? nil : result.output
                        if result.status == 0 { branch = ""; target = "HEAD"; destination = ""; mode = .newBranch; selection = URL(fileURLWithPath: location).resolvingSymlinksInPath().path; revision = UUID() }
                    }
                }.buttonStyle(.borderedProminent).disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (mode == .newBranch && branch.isEmpty) || (mode == .existingBranch && existingBranch.isEmpty))
            }
        }.disabled(model.isGitBusy || loading)
    }
}
