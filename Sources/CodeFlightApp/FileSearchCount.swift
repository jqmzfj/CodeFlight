import SwiftUI
import Foundation

struct FileSearchRequest: Equatable, Sendable {
    let content: String
    let query: String
}

enum FileSearchCounter {
    /// Match the preview highlighter's literal, case-insensitive, non-overlapping
    /// search. Keep only a count; no array of lines or all matching ranges.
    static func count(_ request: FileSearchRequest) -> Int? {
        guard !request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return 0 }
        let source = request.content as NSString
        var remaining = NSRange(location: 0, length: source.length)
        var count = 0
        while remaining.length > 0 {
            if Task.isCancelled { return nil }
            let found = source.range(of: request.query, options: [.caseInsensitive], range: remaining)
            guard found.location != NSNotFound, found.length > 0 else { break }
            count += 1
            let end = NSMaxRange(found)
            remaining = NSRange(location: end, length: source.length - end)
        }
        return Task.isCancelled ? nil : count
    }

    static func result(for request: FileSearchRequest) async -> Int? {
        // Coalesce typing without delaying visible highlighting or the text field.
        do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return nil }
        let worker = Task.detached(priority: .userInitiated) { count(request) }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }
}

struct FileSearchCount: View {
    let content: String?
    let query: String
    let language: AppLanguage
    @State private var completedRequest: FileSearchRequest?
    @State private var count = 0
    private var request: FileSearchRequest? { content.map { FileSearchRequest(content: $0, query: query) } }
    private var current: Bool { request != nil && completedRequest == request }

    var body: some View {
        Text(current ? "\(count)" : "…")
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            .accessibilityLabel(Copy.t("匹配次数", "Matches", language: language))
            .accessibilityValue(current ? "\(count)" : Copy.t("正在搜索", "Searching", language: language))
            .help(Copy.t("当前显示的预览内容中的匹配次数", "Matches in the displayed preview", language: language))
            .task(id: request) {
                guard let input = request else { return }
                guard let result = await FileSearchCounter.result(for: input), !Task.isCancelled else { return }
                count = result
                completedRequest = input
            }
    }
}
