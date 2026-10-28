import SwiftUI

struct GitComparisonTarget: Identifiable {
    let id: String
}

struct GitComparisonFile: Identifiable, Sendable {
    let path: String
    let oldPath: String?
    let status: String
    var id: String { path }
}

struct GitBranchComparison: Sendable {
    let current: String
    let target: String
    let base: String
    let files: [GitComparisonFile]
    let currentOnly: Int
    let targetOnly: Int
}

extension GitService {
    static func compareBranches(current: String = "HEAD", target: String, fromMergeBase: Bool, at path: String) async -> (GitBranchComparison?, String?) {
        guard let left = await commitHash(current, at: path), let right = await commitHash(target, at: path) else {
            return (nil, "无法读取分支提交，请刷新分支后重试。 / Cannot resolve the branch commits. Refresh and retry.")
        }
        var base = left
        if fromMergeBase {
            let result = await CommandRunner.run(command: "git merge-base \(left) \(right)", cwd: path)
            guard result.status == 0, let hash = result.output.split(whereSeparator: \.isNewline).first,
                  [40, 64].contains(hash.count), hash.allSatisfy(\.isHexDigit) else {
                return (nil, "这两个分支没有可用的共同祖先。 / These branches have no common ancestor.")
            }
            base = String(hash)
        }
        let result = await CommandRunner.run(command: "git --no-pager diff --no-ext-diff --no-textconv --name-status -z --find-renames \(base) \(right) --", cwd: path, outputLimit: 4 * 1024 * 1024)
        guard result.status == 0, !result.truncated else {
            return (nil, result.truncated ? "差异文件列表超过读取限制。 / Changed file list exceeds the read limit." : result.output)
        }
        let fields = result.output.components(separatedBy: "\0")
        var files: [GitComparisonFile] = [], index = 0
        while index + 1 < fields.count, !fields[index].isEmpty {
            let status = fields[index]; index += 1
            if status.hasPrefix("R") || status.hasPrefix("C") {
                guard index + 1 < fields.count else { return (nil, "无法解析重命名记录。 / Cannot parse rename record.") }
                files.append(GitComparisonFile(path: fields[index + 1], oldPath: fields[index], status: status)); index += 2
            } else {
                files.append(GitComparisonFile(path: fields[index], oldPath: nil, status: status)); index += 1
            }
        }
        let counts = await CommandRunner.run(command: "git rev-list --left-right --count \(left)...\(right)", cwd: path)
        let values = counts.output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard counts.status == 0, values.count == 2 else { return (nil, counts.output) }
        return (GitBranchComparison(current: left, target: right, base: base, files: files, currentOnly: values[0], targetOnly: values[1]), nil)
    }

    static func comparisonDiff(_ comparison: GitBranchComparison, file: GitComparisonFile, at path: String) async -> String {
        let paths = ([file.oldPath, file.path].compactMap { $0 }).map(Shell.quote).joined(separator: " ")
        return await CommandRunner.run(command: "git --literal-pathspecs --no-pager diff --no-color --no-ext-diff --no-textconv --find-renames \(comparison.base) \(comparison.target) -- \(paths)", cwd: path).previewOutput
    }
}

struct GitBranchComparisonSheet: View {
    @ObservedObject var model: WorkbenchModel
    let target: String
    @Environment(\.dismiss) private var dismiss
    @State private var comparison: GitBranchComparison?
    @State private var failure: String?
    @State private var selection: String?
    @State private var search = ""
    @State private var fromMergeBase = false
    @State private var contentTab = 0
    @State private var split = true
    @State private var loading = true
    @State private var diffLoading = false
    @State private var diff = ""
    @State private var revision = UUID()
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var targetLabel: String { target.replacingOccurrences(of: "refs/heads/", with: "").replacingOccurrences(of: "refs/remotes/", with: "") }
    private var visible: [GitComparisonFile] { (comparison?.files ?? []).filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) || ($0.oldPath?.localizedCaseInsensitiveContains(search) ?? false) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(text("分支比较", "Compare branches"), systemImage: "arrow.left.arrow.right").font(.headline)
                Text("HEAD → \(targetLabel)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(target)
                Spacer()
                Button { revision = UUID() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).disabled(loading).help(text("刷新比较", "Refresh comparison")).accessibilityLabel(text("刷新比较", "Refresh comparison"))
                Button(text("关闭", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            HStack {
                if contentTab == 0 {
                Picker(text("比较范围", "Scope"), selection: $fromMergeBase) {
                    Text(text("两个分支的差异", "Branch endpoints")).tag(false)
                    Text(text("目标分支引入的改动", "Changes introduced by target")).tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 410)
                } else {
                    Text(text("仅显示所选分支独有的提交", "Commits unique to the selected branch")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(text("差异布局", "Diff layout"), selection: $split) {
                    Text(text("双栏", "Split")).tag(true)
                    Text(text("统一", "Unified")).tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 130)
            }.padding(.horizontal, 14).padding(.bottom, 12)
            Divider()
            if loading { Spacer(); ProgressView(text("正在比较…", "Comparing…")); Spacer() }
            else if let failure {
                ScrollView {
                    Text(failure).font(.system(.caption, design: .monospaced)).foregroundStyle(.orange)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else if let comparison {
                HStack {
                    Text(text("当前分支独有 \(comparison.currentOnly) 个提交 · 目标分支独有 \(comparison.targetOnly) 个提交 · \(comparison.files.count) 个文件", "Current only: \(comparison.currentOnly) commits · Target only: \(comparison.targetOnly) commits · \(comparison.files.count) files"))
                    Spacer()
                    Text("\(comparison.base.prefix(8)) → \(comparison.target.prefix(8))").font(.system(size: 10, design: .monospaced)).help(text("比较的提交快照；刷新可获取最新状态", "Commit snapshot; refresh to use the latest state"))
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 9)
                Divider()
                Picker(text("比较内容", "Comparison content"), selection: $contentTab) {
                    Text(text("文件差异", "Files")).tag(0)
                    Text(text("当前分支独有 (\(comparison.currentOnly))", "Current only (\(comparison.currentOnly))")).tag(1)
                    Text(text("目标分支独有 (\(comparison.targetOnly))", "Target only (\(comparison.targetOnly))")).tag(2)
                }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14).padding(.vertical, 8)
                if contentTab != 0 {
                    GitComparisonCommits(model: model, comparison: comparison, targetSide: contentTab == 2, split: split)
                        .id("\(comparison.current)-\(comparison.target)-\(contentTab)")
                } else {
                    WorkbenchSplit("comparison.files", initial: 240, minimum: 180, otherMinimum: 400) {
                    VStack(spacing: 4) {
                        TextField(text("筛选文件", "Filter files"), text: $search).textFieldStyle(.roundedBorder).padding(8)
                        List(selection: $selection) {
                            ForEach(visible) { file in
                                HStack(spacing: 7) {
                                    Text(String(file.status.prefix(1))).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(file.status.hasPrefix("D") ? .red : file.status.hasPrefix("A") ? .green : .secondary)
                                    Text(file.path).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                                }.tag(file.id).help(file.oldPath.map { "\($0) → \(file.path)" } ?? file.path)
                            }
                        }.listStyle(.sidebar)
                        .overlay {
                            if !search.isEmpty && visible.isEmpty {
                                Text(text("没有匹配的文件", "No matching files")).font(.caption).foregroundStyle(.secondary).padding()
                            }
                        }
                    }.frame(maxWidth: .infinity)
                } second: {
                    Group {
                        if diffLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                        else if selection != nil {
                            GitStructuredDiff(content: diff, language: model.language, split: split, canApply: false, staged: false, oldLabel: fromMergeBase ? text("共同祖先", "Common ancestor") : "HEAD", newLabel: targetLabel, codeLanguage: URL(fileURLWithPath: comparison.files.first(where: { $0.id == selection })?.path ?? "").pathExtension.lowercased(), apply: { _, _, _ in })
                        } else {
                            Text(comparison.files.isEmpty ? text("所选范围内没有文件差异", "No file differences in this range") : text("选择一个文件查看差异", "Select a file to view differences")).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }.frame(maxWidth: .infinity)
                }
                }
            }
        }.frame(minWidth: 760, idealWidth: 1000, maxWidth: .infinity, minHeight: 440, idealHeight: 660, maxHeight: .infinity)
        .resizableSheet(minimumWidth: 760, minimumHeight: 440, language: model.language)
        .task(id: "\(fromMergeBase)-\(revision)") {
            guard let project = model.selectedProject else { return }
            loading = true; comparison = nil; selection = nil; diff = ""; failure = nil
            let result = await GitService.compareBranches(target: target, fromMergeBase: fromMergeBase, at: project.path)
            guard !Task.isCancelled, model.selectedProjectID == project.id else { return }
            comparison = result.0; failure = result.1; loading = false; selection = visible.first?.id
        }
        .task(id: "\(selection ?? "")-\(comparison?.base ?? "")-\(comparison?.target ?? "")") {
            diff = ""; diffLoading = false
            guard let comparison, let file = comparison.files.first(where: { $0.id == selection }), let project = model.selectedProject else { return }
            diffLoading = true
            let result = await GitService.comparisonDiff(comparison, file: file, at: project.path)
            guard !Task.isCancelled, model.selectedProjectID == project.id else { return }
            diff = result; diffLoading = false
        }
        .onChange(of: search) { _ in if !visible.contains(where: { $0.id == selection }) { selection = visible.first?.id } }
        .onChange(of: model.selectedProjectID) { _ in dismiss() }
    }
}
