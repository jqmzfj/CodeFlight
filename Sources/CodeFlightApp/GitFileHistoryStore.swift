import SwiftUI

struct GitFileHistoryContext: Equatable {
    let path: String
    let file: String
}

/// Holds only explicitly requested pages from one frozen file-history snapshot.
@MainActor
final class GitFileHistoryStore: ObservableObject {
    @Published private(set) var entries: [GitFileHistoryEntry] = []
    @Published var selection: String?
    @Published var search = "" { didSet { reconcileSelection() } }
    @Published private(set) var loading = false
    @Published private(set) var hasMore = true
    @Published private(set) var failure: String?
    @Published private(set) var retryRefresh = true
    private var context: GitFileHistoryContext?
    private var snapshot: String?
    private var generation = UUID()

    var visible: [GitFileHistoryEntry] { entries.filter(matches) }
    var selected: GitFileHistoryEntry? { visible.first { $0.id == selection } }

    func selectVisibleCommit() {
        reconcileSelection()
        if selection == nil { selection = visible.first?.id }
    }

    func cancel() { generation = UUID(); loading = false }

    func refresh(_ next: GitFileHistoryContext) async {
        guard !Task.isCancelled else { return }
        if context != next {
            context = next; snapshot = nil; entries = []; selection = nil
            search = ""; hasMore = true
        }
        generation = UUID()
        let request = generation
        loading = true; failure = nil; retryRefresh = true
        defer { if generation == request { loading = false } }
        let page = await GitService.fileHistory(next.file, at: next.path)
        guard generation == request, !Task.isCancelled else { return }
        failure = page.error
        guard page.error == nil else { return }
        if snapshot == page.snapshot, !entries.isEmpty { return }
        snapshot = page.snapshot; entries = page.entries; hasMore = page.hasMore
        // Preserve the live selection, never the selection from before the read.
        reconcileSelection()
    }

    func loadMore() async {
        guard !Task.isCancelled, let context, !loading, hasMore else { return }
        let request = generation
        loading = true; failure = nil; retryRefresh = false
        defer { if generation == request { loading = false } }
        let page = await GitService.fileHistory(context.file, at: context.path,
                                               skip: entries.count, snapshot: snapshot)
        guard generation == request, !Task.isCancelled else { return }
        failure = page.error
        guard page.error == nil else { return }
        snapshot = page.snapshot
        let known = Set(entries.map(\.id))
        entries.append(contentsOf: page.entries.filter { !known.contains($0.id) })
        hasMore = page.hasMore
        reconcileSelection()
    }

    private func matches(_ entry: GitFileHistoryEntry) -> Bool {
        search.isEmpty || "\(entry.commit.subject) \(entry.commit.author) \(entry.id) \(entry.path)"
            .localizedCaseInsensitiveContains(search)
    }
    private func reconcileSelection() {
        if let selection, !entries.contains(where: { $0.id == selection && matches($0) }) {
            self.selection = nil
        }
    }
}
