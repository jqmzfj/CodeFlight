import SwiftUI

/// One lifecycle for creating, renaming and recovering branches: keep the draft
/// on failure and dismiss only once Git has actually finished successfully.
struct GitBranchEditor: View {
    enum Mode {
        case create, rename(String), recover(GitReflogEntry)
    }
    @ObservedObject var model: WorkbenchModel
    let mode: Mode
    var baseCommit: GitCommit? = nil
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draftGuard = SheetDraftGuard()
    @State private var name = ""
    @State private var checkout = true
    @State private var baseBranch = ""
    @State private var submitting = false
    @State private var failure: String?
    @FocusState private var nameFocused: Bool

    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var title: String {
        switch mode {
        case .create: return text("新建分支", "New Branch")
        case .rename: return text("重命名分支", "Rename Branch")
        case .recover: return text("恢复为新分支", "Recover as a New Branch")
        }
    }
    private var action: String {
        switch mode {
        case .create: return text("创建", "Create")
        case .rename: return text("重命名", "Rename")
        case .recover: return text("恢复分支", "Recover Branch")
        }
    }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool {
        guard !trimmedName.isEmpty else { return false }
        if case .rename(let original) = mode { return trimmedName != original }
        return true
    }
    private var dirty: Bool {
        switch mode {
        case .rename(let original): return name != original
        case .recover: return !name.isEmpty
        case .create: return !name.isEmpty || !checkout || baseBranch != (baseCommit?.hash ?? "")
        }
    }
    private func requestClose() { draftGuard.request(dirty: dirty) { dismiss() } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(title, systemImage: "arrow.triangle.branch").font(.system(size: 14, weight: .semibold))
                Spacer()
                if dirty { Text(text("未保存", "Unsaved")).font(.caption).foregroundStyle(.secondary) }
                Button(text("关闭", "Close"), action: requestClose)
                    .controlSize(.small).keyboardShortcut(.cancelAction).disabled(submitting)
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let project = model.selectedProject {
                        Text(project.name).font(.caption).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        switch mode {
                        case .rename(let old):
                            Text(text("当前分支：", "Current branch: ") + old)
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        case .recover(let entry):
                            Text(entry.subject).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(String(entry.hash.prefix(12))).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        case .create: EmptyView()
                        }
                        TextField(text("分支名称", "Branch name"), text: $name)
                            .textFieldStyle(.roundedBorder).focused($nameFocused)
                            .accessibilityLabel(text("分支名称", "Branch name"))
                        switch mode {
                        case .create:
                            Picker(text("基于分支", "Based on"), selection: $baseBranch) {
                                Text(text("当前 HEAD", "Current HEAD")).tag("")
                                if let baseCommit {
                                    Text(String(baseCommit.hash.prefix(8)) + " · " + baseCommit.subject).tag(baseCommit.hash)
                                }
                                ForEach(model.gitBranches, id: \.self) { Text($0).tag("refs/heads/" + $0) }
                                if !model.gitRemoteBranches.isEmpty {
                                    Divider()
                                    ForEach(model.gitRemoteBranches, id: \.self) { Text($0).tag("refs/remotes/" + $0) }
                                }
                            }.pickerStyle(.menu).accessibilityLabel(text("基于分支", "Based on"))
                            Toggle(text("创建后切换到该分支", "Checkout after creating"), isOn: $checkout)
                        case .recover:
                            Text(text("仅创建分支引用，保留当前分支与工作区。", "Creates a branch reference and preserves the current branch and worktree."))
                                .font(.caption).foregroundStyle(.secondary)
                        case .rename: EmptyView()
                        }
                    }.disabled(submitting)
                    if let failure {
                        Text(failure).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if submitting {
                    ProgressView().controlSize(.small)
                    Text(text("正在执行…", "Working…")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(text("取消", "Cancel"), action: requestClose).disabled(submitting)
                Button(action, action: submit).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || submitting || model.isGitBusy || model.selectedProjectID == nil)
            }.padding(16)
        }.frame(minWidth: 420, idealWidth: 480, maxWidth: .infinity, minHeight: 260, idealHeight: 360, maxHeight: .infinity)
            .resizableSheet(minimumWidth: 420, minimumHeight: 260, language: model.language)
            .protectDraft(using: draftGuard, model: model, dirty: { dirty }, busy: { submitting }, context: {
                text("分支表单中有未完成的输入。放弃后将清空输入，仓库分支不受影响。", "The branch form has unfinished input. Discarding clears the form and keeps repository branches.")
            })
            .onAppear {
                if case .rename(let old) = mode { name = old }
                if case .create = mode { baseBranch = baseCommit?.hash ?? "" }
                nameFocused = true
            }
    }

    private func submit() {
        guard !submitting, canSubmit, !model.isGitBusy else { return }
        submitting = true; failure = nil
        let completion: @MainActor (CommandResult) -> Void = { result in
            submitting = false
            if result.status == 0 { dismiss() }
            else {
                let diagnostic = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                failure = diagnostic.isEmpty
                    ? text("分支操作未完成，请查看 Git 操作记录。", "Branch operation failed. Check the Git operation log.") : diagnostic
                nameFocused = true
            }
        }
        switch mode {
        case .create:
            model.createBranch(trimmedName, checkout: checkout, from: baseBranch.isEmpty ? nil : baseBranch, completion: completion)
        case .rename(let old): model.renameBranch(old, to: trimmedName, completion: completion)
        case .recover(let entry): model.createBranch(trimmedName, checkout: false, from: entry.hash, completion: completion)
        }
    }
}
