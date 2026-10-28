import SwiftUI

struct GitPromptSheet: View {
    @ObservedObject var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    let kind: GitPromptKind
    var initialCommit: GitCommit? = nil
    @State private var value = ""
    @State private var submitting = false
    @State private var failure: String?
    @State private var target: GitCommitTarget?
    @State private var inspectedReference: String?
    @State private var mainline = 0
    @FocusState private var valueFocused: Bool

    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var reference: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var usesCommit: Bool { kind != .tagCreate && kind != .tagDelete }
    private var usesMainline: Bool { kind == .revert || kind == .cherryPick }
    private var currentTarget: GitCommitTarget? { inspectedReference == reference ? target : nil }
    private var needsParent: Bool { usesMainline && (currentTarget?.parents.count ?? 0) > 1 }
    private var resolvingConflict: Bool { usesMainline && model.gitOperationState != nil }
    private var hasConflicts: Bool { model.gitChanges.contains(where: \.isConflicted) }
    private var title: String {
        switch kind {
        case .revert: return text("撤销提交", "Revert Commit")
        case .cherryPick: return text("拣选提交", "Cherry-pick Commit")
        case .resetSoft: return text("软重置", "Soft Reset")
        case .resetMixed: return text("混合重置", "Mixed Reset")
        case .resetHard: return text("硬重置", "Hard Reset")
        case .tagCreate: return text("新建标签", "Create Tag")
        case .tagDelete: return text("删除标签", "Delete Tag")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                Button(text("关闭", "Close")) { dismiss() }.controlSize(.small)
                    .keyboardShortcut(.cancelAction).disabled(submitting)
            }
            if let project = model.selectedProject {
                Text(project.name + " · " + model.gitBranch).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            TextField(usesCommit ? text("提交哈希或引用", "Commit hash or ref") : text("标签名称", "Tag name"), text: $value)
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                .focused($valueFocused).disabled(submitting)
            if usesCommit && !reference.isEmpty {
                if let currentTarget {
                    Text(currentTarget.subject).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    if needsParent {
                        Picker(text("主线父提交", "Mainline parent"), selection: $mainline) {
                            Text(text("请选择比较基准", "Choose comparison base")).tag(0)
                            ForEach(Array(currentTarget.parents.enumerated()), id: \.offset) { index, hash in
                                Text(text("父提交", "Parent") + " \(index + 1) · " + String(hash.prefix(12))).tag(index + 1)
                            }
                        }.pickerStyle(.menu).disabled(submitting)
                        Text(text("这是合并提交。将相对所选父提交的改动用于撤销或拣选；通常父提交 1 是合并前的目标分支。", "This is a merge commit. Revert or apply its changes relative to the selected parent. Parent 1 is usually the target branch before the merge."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if inspectedReference == reference {
                    Label(text("未找到有效提交，请检查哈希或引用。", "Commit not found. Check the hash or reference."), systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    HStack { ProgressView().controlSize(.small); Text(text("正在读取提交…", "Reading commit…")).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if kind == .resetHard {
                Label(text("硬重置会丢弃工作区未提交的修改。请确认目标后再执行。", "Hard reset discards uncommitted workspace changes. Verify the target before continuing."), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.caption)
            } else if kind == .resetSoft {
                Text(text("移动当前分支，保留当前工作区和暂存区的内容。", "Move the current branch and keep the working tree and index contents."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if kind == .resetMixed {
                Text(text("移动当前分支，保留工作区文件，将暂存区恢复为所选提交。", "Move the current branch, keep working files, and reset the index to the selected commit."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if kind == .revert {
                Text(text("生成反向提交，保留原有提交历史。", "Create a reversing commit and keep the existing history."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if kind == .cherryPick {
                Text(text("将所选改动应用到当前分支并生成新提交。", "Apply the selected changes to the current branch as a new commit."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure {
                ScrollView {
                    Text(failure).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.frame(height: 100).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            }
            if resolvingConflict {
                Text(hasConflicts
                     ? text("请关闭此窗口，在主界面处理冲突后继续或中止 Git 操作。", "Close this window to resolve conflicts, then continue or abort the Git operation.")
                     : text("当前 Git 操作尚未完成，请关闭此窗口，在提交面板继续或中止。", "The Git operation is pending. Close this window to continue or abort it in the Commit panel."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if submitting { ProgressView().controlSize(.small) }
                Spacer()
                Button(text("取消", "Cancel")) { dismiss() }.disabled(submitting)
                if resolvingConflict {
                    Button(hasConflicts ? text("关闭并处理冲突", "Close and Resolve") : text("关闭并处理", "Close and Review")) { dismiss() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(submitting)
                } else {
                    Button(text("执行", "Run"), action: submit).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(reference.isEmpty || submitting || model.isGitBusy || model.selectedProjectID == nil || (usesCommit && currentTarget == nil) || (needsParent && mainline == 0))
                }
            }
        }
        .padding(24)
        .frame(minWidth: 470, idealWidth: 540, maxWidth: .infinity,
               minHeight: 360, idealHeight: 460, maxHeight: .infinity,
               alignment: .topLeading)
        .resizableSheet(minimumWidth: 470, minimumHeight: 360, language: model.language)
        .interactiveDismissDisabled(submitting)
            .onAppear { value = initialCommit?.hash ?? ""; valueFocused = true }
            .onChange(of: value) { _ in failure = nil }
            .onChange(of: model.selectedProjectID) { _ in dismiss() }
            .task(id: (model.selectedProjectID?.uuidString ?? "") + value) {
                inspectedReference = nil; target = nil; mainline = 0
                guard usesCommit, !reference.isEmpty, let project = model.selectedProject else { return }
                let requested = reference
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                let result = await GitService.commitTarget(requested, at: project.path)
                guard !Task.isCancelled, model.selectedProjectID == project.id, reference == requested else { return }
                target = result; inspectedReference = requested
            }
    }

    private func submit() {
        guard !submitting, !model.isGitBusy, !reference.isEmpty else { return }
        if usesCommit && currentTarget == nil { return }
        if needsParent && mainline == 0 { return }
        submitting = true; failure = nil
        model.gitAdvanced(kind.operation, value: currentTarget?.hash ?? reference, mainline: needsParent ? mainline : nil) { result in
            submitting = false
            if result.status == 0 { dismiss() }
            else if result.status != 130 {
                failure = result.output
                if resolvingConflict, let conflict = model.gitChanges.first(where: \.isConflicted) { model.openDiff(conflict) }
                else { valueFocused = true }
            }
        }
    }
}
