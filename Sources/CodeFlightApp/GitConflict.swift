import SwiftUI
import AppKit

enum GitOperationState: String {
    case merging, rebasing, cherryPicking, reverting
    var continueOperation: GitAdvancedOperation {
        switch self {
        case .merging: return .mergeContinue
        case .rebasing: return .rebaseContinue
        case .cherryPicking: return .cherryPickContinue
        case .reverting: return .revertContinue
        }
    }
    var abortOperation: GitAdvancedOperation {
        switch self {
        case .merging: return .mergeAbort
        case .rebasing: return .rebaseAbort
        case .cherryPicking: return .cherryPickAbort
        case .reverting: return .revertAbort
        }
    }
    var skipOperation: GitAdvancedOperation? {
        switch self {
        case .merging: return nil
        case .rebasing: return .rebaseSkip
        case .cherryPicking: return .cherryPickSkip
        case .reverting: return .revertSkip
        }
    }
    func title(_ language: AppLanguage) -> String {
        switch self {
        case .merging: return Copy.t("合并进行中", "Merge in progress", language: language)
        case .rebasing: return Copy.t("变基进行中", "Rebase in progress", language: language)
        case .cherryPicking: return Copy.t("拣选进行中", "Cherry-pick in progress", language: language)
        case .reverting: return Copy.t("撤销提交进行中", "Revert in progress", language: language)
        }
    }
}

struct GitConflictSnapshot {
    static let byteLimit = 2 * 1024 * 1024
    let indexState: String
    let originalData: Data?
    let permissions: Int
    let ours: String?
    let theirs: String?
    let base: String?
    let working: String
    let editable: Bool
    let reason: String
}

extension GitService {
    static func operationState(at path: String) async -> GitOperationState? {
        let gitDirectory = await CommandRunner.run(command: "git rev-parse --absolute-git-dir", cwd: path)
        guard gitDirectory.status == 0 else { return nil }
        let directory = URL(fileURLWithPath: gitDirectory.output.trimmingCharacters(in: .whitespacesAndNewlines))
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.appendingPathComponent("rebase-merge").path) || fm.fileExists(atPath: directory.appendingPathComponent("rebase-apply").path) { return .rebasing }
        if fm.fileExists(atPath: directory.appendingPathComponent("MERGE_HEAD").path) { return .merging }
        if fm.fileExists(atPath: directory.appendingPathComponent("CHERRY_PICK_HEAD").path) { return .cherryPicking }
        if fm.fileExists(atPath: directory.appendingPathComponent("REVERT_HEAD").path) { return .reverting }
        return nil
    }

    static func conflictSnapshot(_ file: String, at path: String) async -> GitConflictSnapshot {
        let index = await CommandRunner.run(command: "git --literal-pathspecs ls-files -u -z -- \(Shell.quote(file))", cwd: path)
        var stages: [Int: (mode: String, hash: String)] = [:]
        for entry in index.output.split(separator: "\0") {
            let metadata = entry.split(separator: "\t", maxSplits: 1).first?.split(separator: " ") ?? []
            if metadata.count == 3, let stage = Int(metadata[2]) { stages[stage] = (String(metadata[0]), String(metadata[1])) }
        }
        let url = URL(fileURLWithPath: path).appendingPathComponent(file)
        let disk = await Task.detached(priority: .userInitiated) { () -> (Data?, Bool) in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return (nil, true) }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= GitConflictSnapshot.byteLimit,
                  let data = try? Data(contentsOf: url) else { return (nil, false) }
            return (data, true)
        }.value
        var textByStage: [Int: String] = [:]
        var editable = disk.1 && !stages.isEmpty
        for stage in [1, 2, 3] {
            guard let entry = stages[stage] else { continue }
            guard entry.mode == "100644" || entry.mode == "100755" else { editable = false; continue }
            let size = await CommandRunner.run(command: "git cat-file -s \(Shell.quote(entry.hash))", cwd: path)
            guard let count = Int(size.output.trimmingCharacters(in: .whitespacesAndNewlines)), count <= GitConflictSnapshot.byteLimit else { editable = false; continue }
            let blob = await CommandRunner.run(command: "git cat-file blob \(Shell.quote(entry.hash)) | /usr/bin/base64", cwd: path, outputLimit: GitConflictSnapshot.byteLimit * 2)
            guard blob.status == 0, !blob.truncated, let bytes = Data(base64Encoded: blob.output, options: .ignoreUnknownCharacters), bytes.count == count, let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else { editable = false; continue }
            textByStage[stage] = text
        }
        let working: String
        if let data = disk.0 {
            if let value = String(data: data, encoding: .utf8), !value.contains("\0") { working = value }
            else { editable = false; working = "" }
        } else { working = "" }
        return GitConflictSnapshot(indexState: index.output, originalData: disk.0, permissions: stages[2]?.mode == "100755" || (stages[2] == nil && stages[3]?.mode == "100755") ? 0o755 : 0o644, ours: textByStage[2], theirs: textByStage[3], base: textByStage[1], working: working, editable: editable,
                                   reason: "此文件包含二进制、符号链接、非 UTF-8 内容或超过 2 MB。可选择完整版本，或在外部处理后标记解决。 / This file is binary, a symlink, non-UTF-8 or larger than 2 MB. Choose a full version or resolve externally.")
    }

    static func containsConflictMarkers(_ text: String) -> Bool {
        GitConflictBlocks.containsMarkers(text)
    }

    static func saveConflict(_ file: String, result: String?, snapshot: GitConflictSnapshot, at path: String) async -> CommandResult {
        guard snapshot.editable, !snapshot.indexState.isEmpty else { return CommandResult(output: "此文件不支持直接编辑，请重新读取冲突。 / Reload this conflict before editing.", status: 1) }
        if let result, containsConflictMarkers(result) { return CommandResult(output: "结果中仍有冲突标记，请先完成处理。 / Resolve the remaining conflict markers first.", status: 1) }
        let index = await CommandRunner.run(command: "git --literal-pathspecs ls-files -u -z -- \(Shell.quote(file))", cwd: path)
        guard index.status == 0, index.output == snapshot.indexState else { return CommandResult(output: "冲突状态已被其他操作改变，请重新读取后处理。 / The index changed. Reload the conflict.", status: 1) }
        let url = URL(fileURLWithPath: path).appendingPathComponent(file)
        let saved = await Task.detached(priority: .userInitiated) { () -> CommandResult in
            do {
                let fm = FileManager.default
                let attributes = try? fm.attributesOfItem(atPath: url.path)
                if let attributes {
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= GitConflictSnapshot.byteLimit else {
                        return CommandResult(output: "磁盘文件的类型或大小已改变，请重新读取。 / The disk file changed. Reload it.", status: 1)
                    }
                }
                let current = attributes == nil ? nil : try Data(contentsOf: url)
                guard current == snapshot.originalData else { return CommandResult(output: "磁盘文件已被其他程序修改，未覆盖文件。请重新读取后处理。 / Another program modified the file. Reload before saving.", status: 1) }
                if let result {
                    try Data(result.utf8).write(to: url, options: .atomic)
                    try fm.setAttributes([.posixPermissions: attributes?[.posixPermissions] ?? snapshot.permissions], ofItemAtPath: url.path)
                }
                return CommandResult(output: "", status: 0)
            } catch { return CommandResult(output: error.localizedDescription, status: 1) }
        }.value
        guard saved.status == 0 else { return saved }
        return await CommandRunner.run(command: result == nil ? "git --literal-pathspecs rm -- \(Shell.quote(file))" : "git --literal-pathspecs add -- \(Shell.quote(file))", cwd: path)
    }

    static func markConflictResolved(_ file: String, at path: String) async -> CommandResult {
        let index = await CommandRunner.run(command: "git --literal-pathspecs ls-files -u -z -- \(Shell.quote(file))", cwd: path)
        guard index.status == 0, !index.output.isEmpty else { return CommandResult(output: "此文件已不处于冲突状态，请刷新。 / This file is no longer conflicted. Refresh the changes.", status: 1) }
        let check = await CommandRunner.run(command: "LC_ALL=C git --literal-pathspecs diff --check -- \(Shell.quote(file))", cwd: path)
        guard !check.output.contains("leftover conflict marker") else { return CommandResult(output: "文件中仍有冲突标记，请处理后再标记解决。 / The file still contains conflict markers.", status: 1) }
        let exists = FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(file).path)
        return await CommandRunner.run(command: exists ? "git --literal-pathspecs add -- \(Shell.quote(file))" : "git --literal-pathspecs rm -- \(Shell.quote(file))", cwd: path)
    }

    static func skipOperation(_ state: GitOperationState, at path: String) async -> CommandResult {
        guard state.skipOperation != nil, await operationState(at: path) == state else {
            return CommandResult(output: "Git 操作状态已改变，请刷新后重试。合并不支持跳过。 / Git operation changed. Refresh and retry. Merge cannot be skipped.", status: 1)
        }
        let command: String
        switch state {
        case .rebasing: command = "git rebase --skip"
        case .cherryPicking: command = "git cherry-pick --skip"
        case .reverting: command = "git revert --skip"
        case .merging: return CommandResult(output: "Merge cannot be skipped.", status: 1)
        }
        return await CommandRunner.run(command: command, cwd: path, environment: ["GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true"])
    }

    static func continueOperation(_ state: GitOperationState, at path: String) async -> CommandResult {
        let command: String
        switch state {
        case .merging: command = "git commit --no-edit"
        case .rebasing: command = "git rebase --continue"
        case .cherryPicking: command = "git cherry-pick --continue"
        case .reverting: command = "git revert --continue"
        }
        return await CommandRunner.run(command: command, cwd: path, environment: ["GIT_EDITOR": "true", "GIT_SEQUENCE_EDITOR": "true"])
    }
}

@MainActor
final class GitConflictDocument: ObservableObject {
    let id = UUID()
    let file: String
    let projectPath: String
    @Published var snapshot: GitConflictSnapshot?
    @Published var result = ""
    @Published var deleteResult = false
    @Published var loading = true
    init(file: String, projectPath: String) { self.file = file; self.projectPath = projectPath }
    var isDirty: Bool { guard let snapshot else { return false }; return deleteResult || result != snapshot.working }
    func load() async {
        let value = await GitService.conflictSnapshot(file, at: projectPath)
        guard !Task.isCancelled else { return }
        snapshot = value; result = value.working; deleteResult = false; loading = false
    }
}

struct GitConflictEditor: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var document: GitConflictDocument
    @State private var showBase = false
    @State private var showBlocks = true
    @State private var blocks: [GitConflictBlock] = []
    @State private var parsedResult = ""
    @State private var parsedHasMarkers = false
    @State private var blockIndex = 0
    @State private var lastChoice: (before: String, after: String)?
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var change: GitChange { GitChange(path: document.file, state: "UU") }
    private var displayedBlock: GitConflictBlock? {
        guard showBlocks, blocks.indices.contains(blockIndex), !document.deleteResult else { return nil }
        return blocks[blockIndex]
    }
    private var currentBlock: GitConflictBlock? { parsedResult == document.result ? displayedBlock : nil }
    private var resultHasMarkers: Bool { parsedResult != document.result || parsedHasMarkers }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(text("解决冲突", "Resolve conflict"), systemImage: "arrow.triangle.merge").font(.system(size: 12, weight: .semibold))
                if document.isDirty { Text(text("未保存", "Unsaved")).font(.system(size: 10)).foregroundStyle(.orange) }
                Spacer()
                Button(text("重新读取", "Reload")) { model.reloadConflictDocument() }.disabled(model.isGitBusy)
                Button(text("文件已在外部处理，标记解决", "Mark externally resolved")) { model.markConflictResolved(change) }.disabled(model.isGitBusy)
            }.buttonStyle(.borderless).font(.system(size: 11)).padding(10)
            if model.gitOperationState == .rebasing {
                Text(text("变基时，当前版本是变基目标；传入版本是正在重放的提交。", "During rebase, ours is the target history; theirs is the commit being replayed."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.bottom, 8)
            }
            Divider()
            if document.loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let snapshot = document.snapshot {
                if snapshot.editable {
                    HStack(spacing: 10) {
                        if !blocks.isEmpty {
                            Button { blockIndex = max(0, blockIndex - 1) } label: { Image(systemName: "chevron.up") }
                                .disabled(blockIndex == 0).help(text("上一个冲突", "Previous conflict"))
                            Text(text("冲突", "Conflict") + " \(blockIndex + 1) / \(blocks.count)").monospacedDigit()
                            Button { blockIndex = min(blocks.count - 1, blockIndex + 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(blockIndex + 1 >= blocks.count).help(text("下一个冲突", "Next conflict"))
                            Button(showBlocks ? text("查看整份版本", "Show full versions") : text("只看当前冲突块", "Show conflict block")) { showBlocks.toggle(); showBase = false }
                        } else if !resultHasMarkers, !document.deleteResult {
                            Label(text("冲突标记已清除，请检查结果后保存", "Markers cleared; review the result and save"), systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        }
                        if blocks.isEmpty {
                            Button(showBlocks ? text("整份版本操作", "Full version actions") : text("返回结果检查", "Review result")) { showBlocks.toggle(); showBase = false }
                        }
                        Spacer()
                        if displayedBlock != nil {
                            Menu(text("采用两侧", "Accept both")) {
                                Button(text("先当前，再传入", "Ours then theirs")) { choose(.oursThenTheirs) }
                                Button(text("先传入，再当前", "Theirs then ours")) { choose(.theirsThenOurs) }
                            }.menuStyle(.borderlessButton).fixedSize()
                        }
                        if let lastChoice, document.result == lastChoice.after {
                            Button(text("撤销上次选择", "Undo last choice")) { document.result = lastChoice.before; self.lastChoice = nil }
                        }
                    }.buttonStyle(.borderless).font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 8).disabled(model.isGitBusy || parsedResult != document.result)
                    Divider()
                    WorkbenchSplit("conflict.result", axis: .horizontal, initial: 220, minimum: 110, otherMinimum: 120, resizesSecond: true) {
                    WorkbenchSplit("conflict.sources", initial: 400, minimum: 200, otherMinimum: 200) {
                        sourcePane(title: text("当前版本（Ours）", "Ours"), content: displayedBlock?.ours ?? snapshot.ours, base: displayedBlock != nil ? displayedBlock?.base : snapshot.base, isOurs: true)
                    } second: {
                        sourcePane(title: text("传入版本（Theirs）", "Theirs"), content: displayedBlock?.theirs ?? snapshot.theirs, base: nil, isOurs: false)
                    }.frame(maxHeight: .infinity)
                    } second: {
                    VStack(spacing: 0) {
                    HStack {
                        Text(text("合并结果", "Merge result")).font(.system(size: 11, weight: .semibold))
                        if document.deleteResult { Text(text("将删除此文件", "File will be deleted")).font(.system(size: 11)).foregroundStyle(.orange) }
                        else if resultHasMarkers { Text(parsedResult != document.result ? text("正在检查结果…", "Checking result…") : text("仍有冲突标记", "Conflict markers remain")).font(.system(size: 10)).foregroundStyle(.orange) }
                        Spacer()
                        Button(text("保存并标记解决", "Save and resolve")) { model.saveConflictDocument() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                            .disabled(model.isGitBusy || (!document.deleteResult && resultHasMarkers))
                    }.padding(10)
                    if document.deleteResult {
                        VStack(spacing: 8) { Image(systemName: "trash").foregroundStyle(.secondary); Text(text("选择了删除结果", "Deletion selected")).font(.caption); Button(text("恢复磁盘内容", "Restore disk content")) { document.deleteResult = false; document.result = snapshot.working } }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        TextEditor(text: $document.result).font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(8).disabled(model.isGitBusy)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(snapshot.reason).font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack {
                            Button(text("采用当前版本并解决", "Accept ours and resolve")) { model.resolveConflict(change, using: .ours) }
                            Button(text("采用传入版本并解决", "Accept theirs and resolve")) { model.resolveConflict(change, using: .theirs) }
                        }.disabled(model.isGitBusy)
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }.background(Color(nsColor: .textBackgroundColor)).task { await document.load() }
        .task(id: document.result) {
            let source = document.result
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            let parsed = await Task.detached(priority: .userInitiated) { (GitConflictBlocks.parse(source), GitConflictBlocks.containsMarkers(source)) }.value
            guard !Task.isCancelled, source == document.result else { return }
            parsedResult = source; blocks = parsed.0; parsedHasMarkers = parsed.1
            blockIndex = min(blockIndex, max(0, parsed.0.count - 1))
            if lastChoice?.after != source { lastChoice = nil }
        }
    }

    private func choose(_ choice: GitConflictChoice) {
        guard !model.isGitBusy, let block = currentBlock,
              let updated = GitConflictBlocks.replacing(block, choice: choice, in: document.result, expected: parsedResult) else { return }
        lastChoice = (document.result, updated)
        document.result = updated
        showBase = false
    }

    private func sourcePane(title: String, content: String?, base: String?, isOurs: Bool) -> some View {
        let showingBase = isOurs && showBase && base != nil
        let displayedContent = showingBase ? base : content
        return VStack(spacing: 0) {
            HStack {
                Text(showingBase ? text("共同祖先（Base）", "Base") : title).font(.system(size: 11, weight: .medium))
                Spacer()
                if isOurs, base != nil { Button(showBase ? text("显示当前版本", "Show ours") : text("查看祖先", "Show base")) { showBase.toggle() } }
                Button(displayedBlock != nil ? text("采用此块", "Accept block") : displayedContent == nil ? text("采用删除", "Accept deletion") : text("采用整份版本", "Accept full version")) {
                    if currentBlock != nil { choose(isOurs ? .ours : .theirs) }
                    else {
                        document.deleteResult = displayedContent == nil
                        if let displayedContent { lastChoice = (document.result, displayedContent); document.result = displayedContent }
                    }
                }.disabled(model.isGitBusy || parsedResult != document.result || (displayedBlock != nil && showingBase) || (showBlocks && displayedBlock == nil))
            }.buttonStyle(.borderless).font(.system(size: 10)).padding(8)
            Divider()
            if let displayedContent, !displayedContent.isEmpty {
                CodePreview(file: document.file, content: displayedContent, search: "", appLanguage: model.language)
            } else {
                Text(displayedContent == nil ? text("此版本中没有该文件", "File absent in this version") : text("此块为空", "This side is empty"))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(10)
            }
        }.frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
    }
}
