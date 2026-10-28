import SwiftUI

struct GitInteractiveRebaseSheet: View {
    @ObservedObject var model: WorkbenchModel
    let base: GitCommit
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draftGuard = SheetDraftGuard()
    @State private var snapshot: GitRebaseSnapshot?
    @State private var steps: [GitRebaseStep] = []
    @State private var selection: String?
    @State private var loading = true
    @State private var submitting = false
    @State private var failure: String?
    @State private var acknowledged = false
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var dirty: Bool { !pending && snapshot.map { steps != $0.steps } == true }
    private var pending: Bool { model.gitOperationState != nil }
    private var selectedIndex: Int? { steps.firstIndex { $0.id == selection } }
    private var planError: String? { snapshot.flatMap { GitService.rebasePlanError(steps, snapshot: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(text("交互式变基", "Interactive Rebase")).font(.system(size: 15, weight: .semibold))
                Spacer()
                if loading || submitting { ProgressView().controlSize(.small) }
                Button(text("关闭", "Close")) { requestClose() }.keyboardShortcut(.cancelAction).disabled(submitting)
            }
            Text((model.selectedProject?.name ?? "") + " · " + model.gitBranch).font(.caption).foregroundStyle(.secondary)
            Text(text("基准", "Base") + " \(base.hash.prefix(8)) · " + base.subject).font(.caption).lineLimit(1).truncationMode(.middle).help(base.subject)
            Text(text("下列提交从上到下依次执行，基准提交保持不变。选中提交后可调整顺序和操作。", "Commits run from top to bottom; the base stays unchanged. Select a commit to change its action or position."))
                .font(.caption).foregroundStyle(.secondary)
            WorkbenchSplit("rebase.feedback", axis: .horizontal, initial: 120, minimum: 80, otherMinimum: 180, resizesSecond: true) {
                if snapshot != nil {
                    WorkbenchSplit("rebase", initial: 380, minimum: 350, otherMinimum: 260) {
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                Text(text("提交", "Commits") + " (\(steps.count))").font(.caption.weight(.medium))
                                Spacer()
                                Button { move(-1) } label: { Image(systemName: "arrow.up") }
                                    .help(text("上移所选提交", "Move selected commit up")).accessibilityLabel(text("上移提交", "Move commit up"))
                                    .disabled((selectedIndex ?? 0) == 0)
                                Button { move(1) } label: { Image(systemName: "arrow.down") }
                                    .help(text("下移所选提交", "Move selected commit down")).accessibilityLabel(text("下移提交", "Move commit down"))
                                    .disabled(selectedIndex == nil || selectedIndex == steps.count - 1)
                            }.buttonStyle(.borderless).padding(9)
                            Divider()
                            List(selection: $selection) {
                                ForEach(steps) { step in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(step.action.title(model.language)).font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(step.action == .drop ? Color.red : Color.secondary)
                                            Spacer()
                                            Text(String(step.id.prefix(8))).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                        }
                                        Text(step.action == .reword ? (step.message.components(separatedBy: "\n").first ?? "") : step.commit.subject)
                                            .font(.system(size: 12)).lineLimit(2).strikethrough(step.action == .drop)
                                    }.padding(.vertical, 4).tag(step.id)
                                }
                            }.listStyle(.inset).scrollContentBackground(.hidden)
                        }.frame(minWidth: 350, maxWidth: .infinity)
                    } second: {
                        stepEditor.frame(minWidth: 260, maxWidth: .infinity)
                    }.frame(minHeight: 180, maxHeight: .infinity)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12)))
                        .disabled(submitting || pending)
                } else {
                    Text(loading ? text("正在读取提交…", "Loading commits…") : text("未能读取变基计划，请重新读取。", "Could not load the rebase plan. Reload to try again."))
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } second: {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if snapshot != nil && !pending {
                                Toggle(text("我确认改写这些提交的历史", "I confirm rewriting these commits"), isOn: $acknowledged).font(.caption).disabled(submitting)
                                Text(text("已推送的提交改写后需要带保护的强制推送，请先与协作者确认。合并说明会自动保留两次提交的说明，可在完成后修改最近提交说明。", "Published commits will require a force push with lease; coordinate first. Squash keeps both messages; amend the result afterward if needed."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if let error = planError, !pending { Text(error).font(.caption).foregroundStyle(.orange) }
                            if let failure {
                                Text(failure).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                    .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 5)).id("failure")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    }
                    .onChange(of: failure) { value in
                        guard value != nil else { return }
                        DispatchQueue.main.async { proxy.scrollTo("failure", anchor: .top) }
                    }
                }
            }
            HStack {
                if !submitting && !pending {
                    Button(text("重新读取", "Reload")) { draftGuard.request(dirty: dirty) { Task { await load() } } }.disabled(loading)
                }
                Spacer()
                Button(pending ? text("关闭并处理", "Close and resolve") : text("取消", "Cancel")) { requestClose() }.disabled(submitting)
                if !pending {
                    Button(text("开始变基", "Start Rebase")) { start() }.buttonStyle(.borderedProminent)
                        .disabled(loading || submitting || model.isGitBusy || snapshot == nil || planError != nil || !acknowledged)
                }
            }
        }.padding(18).frame(minWidth: 700, idealWidth: 800, maxWidth: .infinity, minHeight: 520, idealHeight: 620, maxHeight: .infinity)
            .resizableSheet(minimumWidth: 700, minimumHeight: 520, language: model.language)
            .protectDraft(using: draftGuard, model: model, dirty: { dirty }, busy: { submitting }, context: {
                text("变基计划中有未执行的调整。放弃后将丢弃顺序、操作和提交说明的修改，仓库历史不会改变。", "The rebase plan has unapplied edits. Discarding clears changes to order, actions and messages; repository history stays unchanged.")
            })
            .task { await load() }
            .onChange(of: model.selectedProjectID) { _ in dismiss() }
    }

    @ViewBuilder private var stepEditor: some View {
        if let index = selectedIndex {
            VStack(alignment: .leading, spacing: 10) {
                Text(steps[index].commit.subject).font(.system(size: 12, weight: .medium)).lineLimit(3)
                Picker(text("操作", "Action"), selection: $steps[index].action) {
                    ForEach(GitRebaseAction.allCases, id: \.self) { action in Text(action.title(model.language)).tag(action) }
                }.pickerStyle(.menu).id(steps[index].id)
                if steps[index].action == .reword {
                    Text(text("新的提交说明", "New commit message")).font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $steps[index].message).font(.system(size: 12)).padding(5)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.12)))
                        .accessibilityLabel(text("新的提交说明", "New commit message"))
                } else {
                    Text(actionDescription(steps[index].action)).font(.caption).foregroundStyle(.secondary)
                    ScrollView { Text(steps[index].commit.message).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                }
                Spacer(minLength: 0)
            }.padding(12)
        } else { Text(text("选择提交以编辑", "Select a commit to edit")).font(.caption).foregroundStyle(.secondary).frame(maxHeight: .infinity) }
    }

    private func actionDescription(_ action: GitRebaseAction) -> String {
        switch action {
        case .pick: return text("按当前顺序应用此提交。", "Apply this commit in the displayed order.")
        case .reword: return ""
        case .squash: return text("合并到前一个保留的提交，同时保留两次提交的说明。", "Combine with the previous retained commit and keep both messages.")
        case .fixup: return text("合并到前一个保留的提交，丢弃此提交的说明。", "Combine with the previous retained commit and discard this message.")
        case .drop: return text("从当前分支的历史中丢弃此提交及其改动。", "Remove this commit and its changes from this branch's history.")
        }
    }

    private func requestClose() { draftGuard.request(dirty: dirty) { dismiss() } }

    private func move(_ offset: Int) {
        guard let index = selectedIndex, steps.indices.contains(index + offset) else { return }
        steps.swapAt(index, index + offset)
    }

    @MainActor private func load() async {
        guard let project = model.selectedProject else { loading = false; return }
        loading = true; failure = nil; snapshot = nil; steps = []; acknowledged = false
        do {
            let value = try await GitService.interactiveRebaseSnapshot(base: base.hash, at: project.path)
            guard !Task.isCancelled, model.selectedProjectID == project.id else { return }
            snapshot = value; steps = value.steps; selection = steps.first?.id
        } catch {
            guard !Task.isCancelled, model.selectedProjectID == project.id else { return }
            failure = error.localizedDescription
        }
        loading = false
    }

    private func start() {
        guard let snapshot else { return }
        submitting = true; failure = nil
        model.startInteractiveRebase(steps, snapshot: snapshot) { result in
            submitting = false
            if result.status == 0 { dismiss() }
            else {
                failure = result.output
                if model.gitOperationState != nil {
                    failure = text("变基尚未完成，请关闭窗口处理冲突，再继续、跳过或中止。\n", "Rebase is unfinished. Close this window, resolve conflicts, then continue, skip or abort.\n") + result.output
                    if let first = model.gitChanges.first(where: \.isConflicted) { model.openDiff(first) }
                }
            }
        }
    }
}
