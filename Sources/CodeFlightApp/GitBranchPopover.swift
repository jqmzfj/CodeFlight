import SwiftUI

struct GitBranchPopover<Advanced: View>: View {
    @ObservedObject var model: WorkbenchModel
    let newBranch: () -> Void
    let renameBranch: () -> Void
    let manageTags: () -> Void
    let manageUpstream: () -> Void
    let compareBranch: (String) -> Void
    let deleteRemoteBranch: (String) -> Void
    @ViewBuilder let advanced: () -> Advanced
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private func filtered(_ branches: [String]) -> [String] { branches.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) } }
    private func run(_ action: () -> Void) { dismiss(); action() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(text("分支", "Branches"), systemImage: "arrow.triangle.branch").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .medium)) }
                    .buttonStyle(.plain).help(text("关闭", "Close")).keyboardShortcut(.cancelAction)
            }.padding(12)
            TextField(text("搜索分支", "Search branches"), text: $search).textFieldStyle(.roundedBorder)
                .focused($searchFocused).padding(.horizontal, 12).padding(.bottom, 10)
            if model.isGitRepository {
                HStack(spacing: 12) {
                    Button { run(newBranch) } label: { Label(text("新建", "New"), systemImage: "plus") }
                    Button { run(manageTags) } label: { Label(text("标签", "Tags"), systemImage: "tag") }
                    Spacer()
                    Button { model.gitAction(.fetch) } label: { Label("Fetch", systemImage: "arrow.clockwise") }
                }.buttonStyle(.borderless).font(.system(size: 12)).padding(.horizontal, 12).padding(.bottom, 10).disabled(model.isGitBusy)
                HStack(spacing: 14) {
                    Button { run { model.gitAction(.pull) } } label: { Label(text("拉取", "Pull"), systemImage: "arrow.down") }
                    Button { run { model.gitAction(.push) } } label: { Label(text("推送", "Push"), systemImage: "arrow.up") }
                    Spacer()
                    if model.isGitBusy { ProgressView().controlSize(.mini) }
                }.buttonStyle(.borderless).font(.system(size: 12)).padding(.horizontal, 12).padding(.bottom, 10).disabled(model.isGitBusy)
                if let tracking = model.gitTracking { GitTrackingSummary(tracking: tracking, language: model.language).padding(.horizontal, 12).padding(.bottom, 9) }
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        section(text("本地分支", "Local branches"), branches: filtered(model.gitBranches), remote: false)
                        if !model.gitRemoteBranches.isEmpty {
                            section(text("远程分支", "Remote branches"), branches: filtered(model.gitRemoteBranches), remote: true)
                        }
                        if filtered(model.gitBranches).isEmpty && filtered(model.gitRemoteBranches).isEmpty {
                            Text(search.isEmpty ? text("尚无提交，提交后可创建分支", "Create the first commit to use branches") : text("没有匹配的分支", "No matching branches"))
                                .font(.caption).foregroundStyle(.secondary).padding(12)
                        }
                    }.padding(.vertical, 6)
                }.frame(height: min(340, max(100, CGFloat(model.gitBranches.count + model.gitRemoteBranches.count) * 32 + 55)))
                Divider()
                HStack {
                    Text(model.gitBranch.isEmpty ? "HEAD" : model.gitBranch).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Menu { advanced() } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize().help(text("仓库管理与高级操作", "Repository management and advanced actions"))
                }.padding(12)
            } else {
                Text(text("当前目录尚未初始化 Git", "This directory is not a Git repository")).font(.caption).foregroundStyle(.secondary).padding(12)
                Button(text("初始化 Git 仓库", "Initialize Git repository")) { run { model.initializeGit() } }.padding(12)
            }
        }.frame(width: 360).onAppear { searchFocused = true }
    }

    private func section(_ title: String, branches: [String], remote: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if !branches.isEmpty {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 4)
                ForEach(branches, id: \.self) { branch in
                    let current = !remote && branch == model.gitBranch
                    HStack(spacing: 4) {
                        Button {
                            if !current { run { remote ? model.checkoutRemoteBranch(branch) : model.checkoutBranch(branch) } }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: current ? "checkmark" : (remote ? "cloud" : "arrow.triangle.branch")).frame(width: 14).foregroundStyle(current ? Color.accentColor : Color.secondary)
                                Text(branch).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                if current { Text(text("当前", "Current")).font(.system(size: 10)).foregroundStyle(.secondary) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).help(branch)
                        Menu {
                            if current {
                                Button(text("重命名…", "Rename…")) { run(renameBranch) }
                                Button(text("设置跟踪分支…", "Set upstream branch…")) { run(manageUpstream) }
                                Button(text("新建分支…", "New branch…")) { run(newBranch) }
                            } else {
                                Button(text("切换", "Checkout")) { run { remote ? model.checkoutRemoteBranch(branch) : model.checkoutBranch(branch) } }
                                Button(text("与当前分支比较…", "Compare with current branch…")) { run { compareBranch((remote ? "refs/remotes/" : "refs/heads/") + branch) } }
                                Divider()
                                Button(text("合并到当前分支", "Merge into current branch")) { run { model.mergeBranch((remote ? "refs/remotes/" : "refs/heads/") + branch) } }
                                Button(text("将当前分支变基到此处", "Rebase current branch onto this")) { run { model.rebaseBranch((remote ? "refs/remotes/" : "refs/heads/") + branch) } }
                                if !remote {
                                    Divider()
                                    Button(text("删除分支…", "Delete branch…"), role: .destructive) { run { model.deleteBranch(branch) } }
                                    Button(text("强制删除分支…", "Force delete branch…"), role: .destructive) { run { model.deleteBranch(branch, force: true) } }
                                } else {
                                    Divider()
                                    Button(text("删除远程分支…", "Delete remote branch…"), role: .destructive) { run { deleteRemoteBranch(branch) } }
                                }
                            }
                        } label: { Image(systemName: "ellipsis").frame(width: 20) }.menuStyle(.borderlessButton).fixedSize()
                    }.disabled(model.isGitBusy).font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 7)
                        .background(current ? Color.accentColor.opacity(0.08) : Color.clear)
                }
            }
        }
    }
}
