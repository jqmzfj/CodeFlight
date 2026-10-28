import SwiftUI

struct GitComparisonCommitPage: Sendable {
    let commits: [GitCommit]
    let hasMore: Bool
}

extension GitService {
    static func comparisonCommits(_ comparison: GitBranchComparison, targetSide: Bool, skip: Int = 0, at path: String) async -> (GitComparisonCommitPage?, String?) {
        let hashes = [comparison.current, comparison.target]
        guard hashes.allSatisfy({ [40, 64].contains($0.count) && $0.allSatisfy(\.isHexDigit) }) else {
            return (nil, "比较快照无效，请刷新。 / Invalid comparison snapshot. Refresh and retry.")
        }
        let included = targetSide ? comparison.target : comparison.current
        let excluded = targetSide ? comparison.current : comparison.target
        // Read one extra record to determine whether another page exists. Both ends
        // are frozen commit IDs, so moving a branch cannot change later pages.
        let result = await CommandRunner.run(command: "git --no-pager log --topo-order -z --skip=\(max(0, skip)) -n 51 --date=iso-strict --format='%H%x00%s%x00%an%x00%ad' \(excluded)..\(included) --", cwd: path, outputLimit: 2 * 1024 * 1024)
        guard result.status == 0, !result.truncated else {
            return (nil, result.truncated ? "提交列表超过单页读取限制。 / Commit page exceeds the read limit." : result.output)
        }
        let fields = result.output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var commits: [GitCommit] = []
        for index in stride(from: 0, to: max(0, fields.count - 3), by: 4) {
            guard [40, 64].contains(fields[index].count), fields[index].allSatisfy(\.isHexDigit) else {
                return (nil, "无法解析提交列表。 / Cannot parse commit list.")
            }
            commits.append(GitCommit(hash: fields[index], subject: fields[index + 1], author: fields[index + 2], date: fields[index + 3]))
        }
        return (GitComparisonCommitPage(commits: Array(commits.prefix(50)), hasMore: commits.count > 50), nil)
    }
}

struct GitComparisonCommits: View {
    @ObservedObject var model: WorkbenchModel
    let comparison: GitBranchComparison
    let targetSide: Bool
    let split: Bool
    @State private var commits: [GitCommit] = []
    @State private var selected: String?
    @State private var search = ""
    @State private var loading = true
    @State private var hasMore = true
    @State private var failure: String?
    @State private var pageRevision = 0
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var visible: [GitCommit] { commits.filter { search.isEmpty || $0.subject.localizedCaseInsensitiveContains(search) || $0.author.localizedCaseInsensitiveContains(search) || $0.hash.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        WorkbenchSplit("comparison.commits", initial: 220, minimum: 180, otherMinimum: 535) {
            VStack(spacing: 0) {
                TextField(text("筛选已加载的提交", "Filter loaded commits"), text: $search).textFieldStyle(.roundedBorder).padding(8)
                List(selection: $selected) {
                    ForEach(visible) { commit in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(commit.subject).font(.system(size: 11)).lineLimit(2)
                            Text("\(commit.hash.prefix(8)) · \(commit.author)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }.tag(commit.hash).padding(.vertical, 3).help("\(commit.subject)\n\(commit.author) · \(commit.date)\n\(commit.hash)")
                    }
                }.listStyle(.sidebar)
                .overlay {
                    if !search.isEmpty && visible.isEmpty && !loading {
                        Text(text("没有匹配的已加载提交", "No matching loaded commits")).font(.caption).foregroundStyle(.secondary).padding()
                    }
                }
                if let failure {
                    ScrollView { Text(failure).font(.system(.caption, design: .monospaced)).foregroundStyle(.orange).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }.frame(maxHeight: 100)
                }
                if loading { ProgressView().controlSize(.small).padding(8) }
                else if hasMore || failure != nil {
                    Button(text(failure == nil ? "加载更多" : "重试", failure == nil ? "Load more" : "Retry")) { pageRevision += 1 }.padding(8)
                }
                Text(text("已加载 \(commits.count) 个提交", "\(commits.count) commits loaded")).font(.caption2).foregroundStyle(.secondary).padding(6)
            }.frame(maxWidth: .infinity)
        } second: {
            if let commit = commits.first(where: { $0.hash == selected }) {
                GitComparisonCommitDetail(model: model, commit: commit, split: split).id(commit.hash)
            } else {
                Text(failure != nil ? text("提交读取失败，请重试", "Unable to read commits. Retry.") : text(commits.isEmpty && !loading ? "此分支没有独有提交" : "选择提交查看改动", commits.isEmpty && !loading ? "No commits unique to this branch" : "Select a commit to view changes"))
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: pageRevision) {
            guard let project = model.selectedProject else { return }
            loading = true; failure = nil
            let result = await GitService.comparisonCommits(comparison, targetSide: targetSide, skip: commits.count, at: project.path)
            guard !Task.isCancelled, model.selectedProjectID == project.id else { return }
            if let page = result.0 {
                commits.append(contentsOf: page.commits); hasMore = page.hasMore
                if selected == nil { selected = visible.first?.hash }
            }
            failure = result.1; loading = false
        }
        .onChange(of: search) { _ in if !visible.contains(where: { $0.hash == selected }) { selected = visible.first?.hash } }
    }
}

private struct GitComparisonCommitDetail: View {
    @ObservedObject var model: WorkbenchModel
    let commit: GitCommit
    let split: Bool
    @State private var files: [String] = []
    @State private var selectedFile: String?
    @State private var description = ""
    @State private var diff = ""
    @State private var loading = true
    @State private var diffLoading = false
    @State private var failure: String?
    @State private var revision = UUID()
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(commit.subject).font(.system(size: 12, weight: .medium)).lineLimit(2).textSelection(.enabled)
                Text("\(commit.hash.prefix(12)) · \(commit.author) · \(commit.date)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                DisclosureGroup(text("提交详情", "Commit details")) {
                    ScrollView { Text(description).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 90)
                }.font(.caption)
            }.padding(10)
            Divider()
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let failure {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(failure).font(.system(.caption, design: .monospaced)).foregroundStyle(.orange).textSelection(.enabled)
                        Button(text("重试", "Retry")) { revision = UUID() }.buttonStyle(.borderless)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            else if files.isEmpty { Text(text("此提交没有文件变更", "No file changes in this commit")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                WorkbenchSplit("comparison.commitFiles", initial: 160, minimum: 130, otherMinimum: 400) {
                    List(files, id: \.self, selection: $selectedFile) { file in
                        Text(file).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).help(file).tag(file)
                    }.listStyle(.sidebar).frame(maxWidth: .infinity)
                } second: {
                    Group {
                        if diffLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                        else { GitStructuredDiff(content: diff, language: model.language, split: split, canApply: false, staged: false, oldLabel: text("父提交", "Parent"), newLabel: String(commit.hash.prefix(8)), codeLanguage: URL(fileURLWithPath: selectedFile ?? "").pathExtension.lowercased(), apply: { _, _, _ in }) }
                    }.frame(minWidth: 400)
                }
            }
        }
        .task(id: revision) {
            guard let project = model.selectedProject else { return }
            loading = true; failure = nil; selectedFile = nil; diff = ""
            let details = await GitService.commitDetails(commit.hash, at: project.path)
            guard !Task.isCancelled, model.selectedProjectID == project.id else { return }
            description = details.description; files = details.files; failure = details.error; loading = false
            if details.error == nil { selectedFile = files.first }
        }
        .task(id: selectedFile) {
            diff = ""
            guard let selectedFile, let project = model.selectedProject else { return }
            diffLoading = true
            let value = await GitService.commitDiff(commit.hash, file: selectedFile, at: project.path)
            guard !Task.isCancelled, model.selectedProjectID == project.id else { return }
            diff = value; diffLoading = false
        }
    }
}
