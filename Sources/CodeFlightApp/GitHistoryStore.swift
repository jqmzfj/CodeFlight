import SwiftUI

struct GitHistoryContext: Hashable, Equatable {
    let path: String
    let scope: String
    var author: String? = nil
    var since: String? = nil
    var until: String? = nil
}

/// A panel owns only the pages explicitly requested by the user. Refreshing
/// an unchanged snapshot keeps older pages, selection and cached graph lanes.
@MainActor
final class GitHistoryStore: ObservableObject {
    @Published private(set) var commits: [GitCommit] = []
    @Published var selectedHash: String?
    @Published var search = "" {
        didSet { reconcileSelection() }
    }
    @Published private(set) var graph: [String: GitGraphRow] = [:]
    @Published private(set) var graphColumns = 1
    @Published private(set) var loading = false
    @Published private(set) var reachedEnd = false
    @Published private(set) var failure: String?
    @Published private(set) var requiresRefresh = false
    @Published private(set) var retryRefresh = true
    /// Author menu values for the current project, read once per repository.
    @Published private(set) var authors: [String] = []
    private var authorsPath: String?
    private var authorsCache: [String: [String]] = [:]
    private var context: GitHistoryContext?
    private var revision: String?
    private var generation = UUID()

    private struct HistoryCacheEntry {
        var commits: [GitCommit]
        var graph: [String: GitGraphRow]
        var graphColumns: Int
        var revision: String?
        var reachedEnd: Bool
        var selectedHash: String?
    }
    private var cache: [GitHistoryContext: HistoryCacheEntry] = [:]

    /// Search and author/date filters all narrow the log; the graph is only
    /// meaningful for a contiguous range, so it is hidden for the first two.
    var isFiltering: Bool {
        if !search.isEmpty { return true }
        guard let context else { return false }
        return context.author != nil || context.since != nil || context.until != nil
    }

    var hasAuthorOrDateFilter: Bool {
        guard let context else { return false }
        return context.author != nil || context.since != nil || context.until != nil
    }

    func loadAuthors(for path: String) async {
        if let cached = authorsCache[path], !cached.isEmpty {
            authors = cached
            authorsPath = path
            return
        }
        if authorsPath == path, !authors.isEmpty { return }
        authorsPath = path
        let values = await GitService.authors(at: path)
        guard !Task.isCancelled else { return }
        authorsCache[path] = values
        if authorsPath == path {
            authors = values
        }
    }

    var visibleCommits: [GitCommit] {
        commits.filter { matches($0) }
    }

    func selectVisibleCommit() {
        reconcileSelection()
        if selectedHash == nil { selectedHash = visibleCommits.first?.hash }
    }

    private func matches(_ commit: GitCommit) -> Bool {
        search.isEmpty || "\(commit.hash) \(commit.subject) \(commit.author) \(commit.refs.joined(separator: " "))".localizedCaseInsensitiveContains(search)
    }

    private func reconcileSelection() {
        if let selectedHash, !commits.contains(where: { $0.hash == selectedHash && matches($0) }) {
            self.selectedHash = nil
        }
    }

    func cancel() {
        generation = UUID()
        loading = false
    }

    func refresh(_ next: GitHistoryContext) async {
        guard !Task.isCancelled else { return }
        if let current = context {
            cache[current] = HistoryCacheEntry(
                commits: commits,
                graph: graph,
                graphColumns: graphColumns,
                revision: revision,
                reachedEnd: reachedEnd,
                selectedHash: selectedHash
            )
        }
        let unchangedContext = context == next
        if !unchangedContext {
            context = next
            if let cached = cache[next] {
                commits = cached.commits
                graph = cached.graph
                graphColumns = cached.graphColumns
                revision = cached.revision
                reachedEnd = cached.reachedEnd
                selectedHash = cached.selectedHash
            } else {
                revision = nil
                commits = []
                graph = [:]
                graphColumns = 1
                selectedHash = nil
                reachedEnd = false
            }
        }
        let expectedRevision = revision
        generation = UUID()
        let request = generation
        defer { if generation == request { loading = false } }
        retryRefresh = true
        loading = true
        failure = nil; requiresRefresh = false
        var page = await read(next, skip: 0, expectedRevision: expectedRevision)
        guard generation == request, !Task.isCancelled else { return }
        if page.requiresRefresh {
            page = await read(next, skip: 0, expectedRevision: nil)
            guard generation == request, !Task.isCancelled else { return }
        }
        loading = false
        failure = page.error; requiresRefresh = page.requiresRefresh
        guard page.error == nil else { return }
        if expectedRevision != nil && page.revision == expectedRevision && !commits.isEmpty {
            return
        }
        revision = page.revision
        await replace(page.commits)
        reachedEnd = !page.hasMore
        if let context {
            cache[context] = HistoryCacheEntry(
                commits: commits,
                graph: graph,
                graphColumns: graphColumns,
                revision: revision,
                reachedEnd: reachedEnd,
                selectedHash: selectedHash
            )
        }
    }

    func loadMore() async {
        guard !Task.isCancelled else { return }
        guard let context, !loading, !reachedEnd, !requiresRefresh else { return }
        let request = generation
        defer { if generation == request { loading = false } }
        retryRefresh = false
        loading = true; failure = nil
        let page = await read(context, skip: commits.count, expectedRevision: revision)
        guard generation == request, !Task.isCancelled else { return }
        loading = false
        failure = page.error; requiresRefresh = page.requiresRefresh
        guard page.error == nil else { return }
        revision = page.revision
        let known = Set(commits.map(\.hash))
        await replace(commits + page.commits.filter { !known.contains($0.hash) })
        reachedEnd = !page.hasMore
    }

    private func replace(_ values: [GitCommit]) async {
        commits = values
        reconcileSelection()
        let calculated = await Task.detached(priority: .userInitiated) {
            GitGraphLayout.rows(values)
        }.value
        guard !Task.isCancelled else { return }
        graph = calculated
        graphColumns = calculated.values.map(\.width).max() ?? 1
    }

    private func read(_ context: GitHistoryContext, skip: Int, expectedRevision: String?) async -> GitHistoryPage {
        await GitService.historyPage(at: context.path, skip: skip, allBranches: context.scope == "--all",
                                     expectedRevision: expectedRevision,
                                     reference: context.scope.hasPrefix("refs/") ? context.scope : nil,
                                     author: context.author, since: context.since, until: context.until)
    }
}
