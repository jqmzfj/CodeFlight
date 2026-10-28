import SwiftUI

struct GitStructuredDiff: View {
    let content: String
    let language: AppLanguage
    let split: Bool
    let canApply: Bool
    let staged: Bool
    let oldLabel: String
    let newLabel: String
    var codeLanguage = ""
    var discard: ((Int, String) -> Void)? = nil
    let apply: (Int, String, Bool) -> Void
    @AppStorage("layout.diff.leftFraction") private var leftFraction = 0.5
    @State private var horizontal = GitDiffHorizontalState()
    @State private var readingTracker = GitDiffReadingTracker()
    @State private var presentation: GitDiffPresentation?
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: language) }
    var body: some View {
        Group {
            if let presentation, presentation.document.source == content, !presentation.document.hunks.isEmpty {
                let document = presentation.document
                GeometryReader { geometry in
                    let fullWidth = max(split ? 365 : 560, geometry.size.width)
                    let columnSpace = fullWidth - 1
                    let leftWidth = SplitSizing.fitted(columnSpace * (leftFraction.isFinite ? leftFraction : 0.5), to: 180...(columnSpace - 180))
                    let rightWidth = columnSpace - leftWidth
                    ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                    ScrollView(split ? [.vertical] : [.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if split {
                                HStack(spacing: 0) {
                                    Text(oldLabel).padding(.horizontal, 10).frame(width: leftWidth, alignment: .leading)
                                    Color.clear.frame(width: 1)
                                    Text(newLabel).padding(.horizontal, 10).frame(width: rightWidth, alignment: .leading)
                                }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.vertical, 8)
                            }
                            ForEach(split ? presentation.splitRows : presentation.unifiedRows) { entry in
                                VStack(alignment: .leading, spacing: 0) {
                                switch entry.content {
                                case .header(let header):
                                    hunkHeader(header, index: entry.hunk, document: document,
                                               fullWidth: fullWidth, leftWidth: split ? leftWidth : nil)
                                case .split(let row):
                                    HStack(spacing: 0) {
                                        cell(number: row.oldLine, value: row.oldText, tint: row.changed ? .red : .clear, width: leftWidth, side: .old)
                                        Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
                                        cell(number: row.newLine, value: row.newText, tint: row.changed ? .green : .clear, width: rightWidth, side: .new)
                                    }.frame(height: 21)
                                case .unified(let line):
                                    code(PreviewLinePolicy.lines(in: line).first ?? " ").fixedSize(horizontal: true, vertical: true)
                                        .padding(.horizontal, 12).frame(minWidth: max(560, geometry.size.width), minHeight: 21, alignment: .leading)
                                        .background(line.hasPrefix("+") ? Color.green.opacity(0.07) : line.hasPrefix("-") ? Color.red.opacity(0.07) : .clear)
                                }
                                }
                                .id((split ? "split-" : "unified-") + entry.id)
                                .background { GitDiffReadingMarker(tracker: readingTracker, split: split, location: entry.location) }
                            }
                        }.textSelection(.enabled).frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                    .overlay(alignment: .topLeading) {
                        if split {
                            SplitDivider(axis: .vertical,
                                dimension: Binding(get: { leftWidth }, set: { leftFraction = Double($0 / columnSpace) }),
                                range: 180...(columnSpace - 180), reset: { leftFraction = 0.5 })
                                .frame(width: SplitSizing.divider)
                                .offset(x: leftWidth - 2)
                        }
                    }
                    .background {
                        if split {
                            GitDiffHorizontalGestures(leftWidth: leftWidth) { side, delta in
                                let width = side == .old ? leftWidth : rightWidth
                                guard horizontal.maximum(side, column: width) > 0 else { return false }
                                horizontal.set(side, offset: horizontal.offset(side, column: width) + delta, column: width)
                                return true
                            }
                        }
                    }
                    if split && (horizontal.maximum(.old, column: leftWidth) > 0 || horizontal.maximum(.new, column: rightWidth) > 0) {
                        Divider()
                        HStack(spacing: 0) {
                            scroller(.old, width: leftWidth)
                            Divider().frame(width: 1)
                            scroller(.new, width: rightWidth)
                        }.frame(width: fullWidth, height: 14)
                    }
                    }
                    .task(id: split) {
                        let mode = split
                        guard let location = readingTracker.locations[!mode], let id = presentation.rowID(for: location, split: mode) else { return }
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        proxy.scrollTo((mode ? "split-" : "unified-") + id, anchor: .top)
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        if let target = (mode ? presentation.splitRows : presentation.unifiedRows).first(where: { $0.id == id }) {
                            readingTracker.align(location: target.location, split: mode)
                        }
                    }
                    .onPreferenceChange(GitDiffWidthPreference.self) { horizontal.record($0) }
                    .onChange(of: leftWidth) { _ in horizontal.fit(old: leftWidth, new: rightWidth) }
                    .onChange(of: rightWidth) { _ in horizontal.fit(old: leftWidth, new: rightWidth) }
                    }
                }.background(Color(nsColor: .textBackgroundColor))
            } else { DiffPreview(content: content) }
        }.onReceive(NotificationCenter.default.publisher(for: WorkbenchLayout.didReset)) { _ in leftFraction = 0.5 }
        .task(id: content) {
            horizontal = GitDiffHorizontalState()
            readingTracker = GitDiffReadingTracker()
            let worker = Task.detached(priority: .userInitiated) { GitDiffPresentation(content) }
            let parsed = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            presentation = parsed
        }
    }
    private func hunkHeader(_ header: String, index: Int, document: GitDiffDocument,
                            fullWidth: CGFloat, leftWidth: CGFloat?) -> some View {
        HStack(spacing: 0) {
            if let leftWidth {
                HStack(spacing: 8) { hunkActions(index, document: document); Spacer(minLength: 0) }
                    .padding(.horizontal, 10).frame(width: leftWidth, alignment: .leading)
                Color.clear.frame(width: 1)
                Text(header).padding(.horizontal, 10)
                    .frame(width: max(0, fullWidth - leftWidth - 1), alignment: .leading)
            } else {
                HStack(spacing: 8) {
                    hunkActions(index, document: document)
                    Text(header)
                    Spacer(minLength: 0)
                }.padding(.horizontal, 10)
            }
        }
        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        .frame(width: fullWidth, height: 30).background(Color.accentColor.opacity(0.06))
    }
    @ViewBuilder private func hunkActions(_ index: Int, document: GitDiffDocument) -> some View {
        if canApply && document.supportsPartialIndex {
            Button(staged ? text("取消暂存此块", "Unstage hunk") : text("暂存此块", "Stage hunk")) {
                apply(index, document.source, staged)
            }.buttonStyle(.borderless).font(.system(size: 10))
            if !staged, let discard {
                Button(text("回滚此块…", "Revert hunk…"), role: .destructive) { discard(index, document.source) }
                    .buttonStyle(.borderless).font(.system(size: 10))
                    .help(text("仅回滚此块的未暂存修改，保留暂存内容", "Revert this unstaged hunk and keep staged content"))
            }
        }
    }
    private func code(_ value: String) -> Text {
        Text(AttributedString(SyntaxHighlighter.attributed(value, language: codeLanguage)))
            .font(.system(size: 12, design: .monospaced))
    }
    private func scroller(_ side: GitDiffSide, width: CGFloat) -> some View {
        GitDiffHorizontalScroller(offset: Binding(
            get: { horizontal.offset(side, column: width) },
            set: { horizontal.set(side, offset: $0, column: width) }),
            maximum: horizontal.maximum(side, column: width),
            viewport: max(1, width - GitDiffHorizontalState.gutter),
            label: side == .old ? text("横向滚动原版本", "Scroll original horizontally") : text("横向滚动新版本", "Scroll revised horizontally"))
            .frame(width: width)
    }
    private func cell(number: Int?, value: String?, tint: Color, width: CGFloat, side: GitDiffSide) -> some View {
        HStack(spacing: 0) {
            Text(number.map(String.init) ?? "").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 42, alignment: .trailing).padding(.trailing, 8)
            code(value.map { PreviewLinePolicy.lines(in: $0).first ?? "" } ?? " ")
                .fixedSize(horizontal: true, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: GitDiffWidthPreference.self, value: [side: geometry.size.width])
                })
                .offset(x: -horizontal.offset(side, column: width))
                .frame(width: max(0, width - GitDiffHorizontalState.gutter), height: 21, alignment: .leading)
                .clipped().help(value ?? "")
        }.frame(width: width, height: 21, alignment: .leading).background(value == nil ? Color.primary.opacity(0.025) : tint.opacity(0.08))
    }
}
