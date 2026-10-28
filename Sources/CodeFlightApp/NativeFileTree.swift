import SwiftUI
import AppKit

/// AppKit only creates cells for visible rows. Directory contents remain unloaded
/// until expansion; refresh/collapse discards obsolete readers and descendants.
@MainActor
final class FileTreeEntry: NSObject {
    let file: FileItem
    let depth: Int
    var children: [FileTreeEntry]?
    let isLimitNotice: Bool
    init(_ file: FileItem, depth: Int = 0, isLimitNotice: Bool = false) {
        self.file = file; self.depth = depth; self.isLimitNotice = isLimitNotice
    }
}

@MainActor
final class FileTreeData {
    private(set) var roots: [FileTreeEntry] = []
    private var reads: [String: Task<Void, Never>] = [:]
    private var generation = UUID()
    var didLoad: ((FileTreeEntry) -> Void)?
    var pendingReadCount: Int { reads.count }

    func replace(_ files: [FileItem]) {
        cancel()
        roots = Self.entries(files, depth: 0)
    }
    private static func entries(_ files: [FileItem], depth: Int) -> [FileTreeEntry] {
        var entries = files.map { FileTreeEntry($0, depth: depth) }
        if files.count >= FileTreeLoader.maxEntriesPerDirectory {
            entries.append(FileTreeEntry(FileItem(name: "", icon: "info.circle", children: [], isDirectory: false), depth: depth, isLimitNotice: true))
        }
        return entries
    }
    func cancel() {
        generation = UUID()
        reads.values.forEach { $0.cancel() }
        reads.removeAll()
    }
    func isLoading(_ path: String) -> Bool { reads[path] != nil }
    func load(_ entry: FileTreeEntry) {
        let path = entry.file.path
        guard entry.file.isDirectory, entry.children == nil, reads[path] == nil else { return }
        let request = generation
        reads[path] = Task { [weak self, weak entry] in
            guard let entry else { return }
            let depth = entry.depth + 1
            let worker = Task.detached(priority: .utility) {
                FileTreeLoader.load(url: URL(fileURLWithPath: path), depth: depth)
            }
            let files = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.generation == request else { return }
            self.reads.removeValue(forKey: path)
            entry.children = Self.entries(files, depth: depth)
            self.didLoad?(entry)
        }
    }
    func collapse(_ entry: FileTreeEntry) {
        let prefix = entry.file.path + "/"
        for key in Array(reads.keys) where key == entry.file.path || key.hasPrefix(prefix) {
            reads.removeValue(forKey: key)?.cancel()
        }
        entry.children = nil
    }
}

struct NativeFileTree: NSViewRepresentable {
    let items: [FileItem]
    @ObservedObject var model: WorkbenchModel
    let search: String
    @Binding var expandedItems: Set<String>

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let outline = FileOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 26
        outline.intercellSpacing = NSSize(width: 0, height: 1)
        outline.indentationPerLevel = 16
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.setAccessibilityLabel(Copy.t("项目文件", "Project files", language: model.language))
        outline.makeMenu = { [weak coordinator = context.coordinator] row in coordinator?.menu(row: row) }
        outline.openSelection = { [weak coordinator = context.coordinator] in coordinator?.openSelection() }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = outline
        scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        context.coordinator.outline = outline
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }
    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) { coordinator.data.cancel() }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: NativeFileTree
        weak var outline: FileOutlineView?
        let data = FileTreeData()
        private var revision: UUID?
        private var project: UUID?
        private var paths: [String] = []
        private var query = ""
        private var updating = false
        private var previewPath: String?
        private var navigationPath: String?
        private var focusRequest: UUID?

        init(_ parent: NativeFileTree) {
            self.parent = parent
            super.init()
            data.didLoad = { [weak self] entry in
                guard let self, let outline = self.outline else { return }
                self.updating = true
                outline.reloadItem(entry, reloadChildren: true)
                self.restoreExpanded(entry.children ?? [])
                self.syncSelection()
                self.updating = false
            }
        }
        func update(_ parent: NativeFileTree) {
            self.parent = parent
            guard let outline else { return }
            outline.setAccessibilityLabel(text("项目文件", "Project files"))
            let nextPaths = parent.items.map(\.path)
            if project != parent.model.selectedProjectID || previewPath != parent.model.selectedFile {
                previewPath = parent.model.selectedFile
                navigationPath = parent.model.selectedFile
            }
            let replaced = project != parent.model.selectedProjectID || revision != parent.model.fileTreeRevision || paths != nextPaths || query != parent.search
            updating = true
            if replaced {
                project = parent.model.selectedProjectID
                revision = parent.model.fileTreeRevision
                paths = nextPaths; query = parent.search
                data.replace(parent.items)
                outline.reloadData()
                restoreExpanded(data.roots)
            } else {
                // Selection and Git state can change without rebuilding directory data.
                outline.enumerateAvailableRowViews { row, index in
                    guard let entry = outline.item(atRow: index) as? FileTreeEntry,
                          let cell = outline.view(atColumn: 0, row: index, makeIfNecessary: false) as? NSTableCellView else { return }
                    self.configure(cell, entry: entry)
                    _ = row
                }
            }
            syncSelection()
            updating = false
            if let request = parent.model.fileNavigatorFocusRequest, request != focusRequest {
                focusRequest = request
                DispatchQueue.main.async { [weak outline] in
                    guard let outline else { return }
                    outline.window?.makeFirstResponder(outline)
                    if outline.selectedRow < 0, outline.numberOfRows > 0 {
                        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    }
                }
            }
        }
        private func restoreExpanded(_ entries: [FileTreeEntry]) {
            guard let outline else { return }
            for entry in entries where entry.file.isDirectory && parent.expandedItems.contains(entry.file.path) {
                outline.expandItem(entry)
                data.load(entry)
                restoreExpanded(entry.children ?? [])
            }
        }
        private func syncSelection() {
            guard let outline else { return }
            // Keep a selected directory when a preview is unchanged. Rebuilding
            // the tree must never open a file or alter an active diff.
            if let selected = outline.item(atRow: outline.selectedRow) as? FileTreeEntry,
               selected.file.path == navigationPath { return }
            for row in 0..<outline.numberOfRows {
                if let entry = outline.item(atRow: row) as? FileTreeEntry, !entry.isLimitNotice, entry.file.path == navigationPath {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                    return
                }
            }
            if replacedSelectionIsFile { outline.deselectAll(nil) }
        }
        private var replacedSelectionIsFile: Bool {
            guard let outline, let entry = outline.item(atRow: outline.selectedRow) as? FileTreeEntry else { return false }
            return !entry.file.isDirectory
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? FileTreeEntry)?.children?.count ?? (item == nil ? data.roots.count : 0)
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let entry = item as? FileTreeEntry { return entry.children![index] }
            return data.roots[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileTreeEntry)?.file.isDirectory == true
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let entry = item as? FileTreeEntry else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("fileCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? makeCell(identifier)
            configure(cell, entry: entry)
            return cell
        }
        private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let icon = NSImageView()
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            icon.translatesAutoresizingMaskIntoConstraints = false
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon); cell.addSubview(label)
            cell.imageView = icon; cell.textField = label
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        private func configure(_ cell: NSTableCellView, entry: FileTreeEntry) {
            let name = entry.isLimitNotice ? text("最多显示 5,000 项，请使用文件筛选定位", "Up to 5,000 entries; use the file filter to find files") : entry.file.name
            let loading = entry.file.isDirectory && data.isLoading(entry.file.path)
            cell.textField?.stringValue = name
            // Keep the navigator quiet for clean files, but surface Git state
            // at the point where users choose a file. This mirrors Xcode and
            // JetBrains navigators without adding another badge column or
            // retaining any extra tree data.
            cell.textField?.textColor = entry.isLimitNotice ? .secondaryLabelColor : statusColor(for: entry.file)
            cell.imageView?.image = NSImage(systemSymbolName: loading ? "arrow.triangle.2.circlepath" : (entry.file.isDirectory ? "folder" : entry.file.icon), accessibilityDescription: nil)
            cell.imageView?.contentTintColor = loading ? .secondaryLabelColor : (entry.isLimitNotice ? .secondaryLabelColor : statusColor(for: entry.file))
            cell.toolTip = loading ? text("正在读取目录…", "Reading directory…") : (entry.isLimitNotice ? name : entry.file.path)
            cell.setAccessibilityLabel(name)
            cell.setAccessibilityValue(loading ? text("正在读取", "Loading") : "")
        }
        private func statusColor(for file: FileItem) -> NSColor {
            guard let project = parent.model.selectedProject else { return .labelColor }
            let root = URL(fileURLWithPath: project.path).standardizedFileURL.path
            let path = URL(fileURLWithPath: file.path).standardizedFileURL.path
            let relative = path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
            var hasUnstaged = false
            var hasStaged = false
            var hasMatch = false
            let directoryPrefix = relative + "/"
            for change in parent.model.gitChanges {
                let matches = change.path == relative || change.originalPath == relative ||
                    (file.isDirectory && (change.path.hasPrefix(directoryPrefix) || change.originalPath?.hasPrefix(directoryPrefix) == true))
                guard matches else { continue }
                hasMatch = true
                if change.isConflicted { return .systemRed }
                hasUnstaged = hasUnstaged || change.isUnstaged
                hasStaged = hasStaged || change.isStaged
            }
            guard hasMatch else { return .labelColor }
            if hasUnstaged { return .systemOrange }
            if hasStaged { return .systemBlue }
            return .systemGreen
        }
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? FileTreeEntry)?.isLimitNotice != true }
        func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
            (item as? FileTreeEntry)?.file.name
        }
        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let entry = notification.userInfo?["NSObject"] as? FileTreeEntry else { return }
            if !updating { parent.expandedItems.insert(entry.file.path) }
            data.load(entry)
            outline?.reloadItem(entry, reloadChildren: false)
        }
        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let entry = notification.userInfo?["NSObject"] as? FileTreeEntry else { return }
            if !updating { parent.expandedItems.remove(entry.file.path) }
            data.collapse(entry)
            outline?.reloadItem(entry, reloadChildren: true)
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating else { return }
            openSelection()
        }
        func openSelection() {
            guard let outline, let entry = outline.item(atRow: outline.selectedRow) as? FileTreeEntry, !entry.isLimitNotice else { return }
            navigationPath = entry.file.path
            if !entry.file.isDirectory {
                parent.model.openFile(entry.file)
                previewPath = parent.model.selectedFile
                if previewPath != entry.file.path { navigationPath = previewPath; syncSelection() }
            }
        }
        private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: parent.model.language) }
        func menu(row: Int) -> NSMenu? {
            guard let outline, let entry = outline.item(atRow: row) as? FileTreeEntry, !entry.isLimitNotice else { return nil }
            let file = entry.file
            let menu = NSMenu()
            func add(_ zh: String, _ en: String, enabled: Bool = true, action: @escaping () -> Void) {
                let item = NSMenuItem(title: text(zh, en), action: #selector(invokeMenu(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = FileMenuAction(action); item.isEnabled = enabled
                menu.addItem(item)
            }
            let model = parent.model
            if !file.isDirectory {
                add("打开文件", "Open file") { model.openFile(file) }
                if model.isGitRepository {
                    menu.addItem(.separator())
                    add("文件历史", "File history") { model.showFileHistory(file.path) }
                    add("逐行追溯", "Annotate") { model.showBlame(file.path) }
                    if let project = model.selectedProject, file.path.hasPrefix(project.path + "/"),
                       let change = model.gitChanges.first(where: { $0.path == String(file.path.dropFirst(project.path.count + 1)) }) {
                        add("查看差异", "Show diff") { model.openDiff(change, staged: !change.isUnstaged) }
                        if change.isUnstaged && !change.isConflicted {
                            add("暂存文件", "Stage file", enabled: !model.isGitBusy) { model.gitFileAction(.stage, path: change.path) }
                        }
                        if change.isStaged { add("取消暂存", "Unstage file", enabled: !model.isGitBusy) { model.gitFileAction(.unstage, path: change.path) } }
                        if change.state == "??", file.name != ".gitignore" {
                            add("忽略此文件", "Ignore this file", enabled: !model.isGitBusy) { model.ignoreUntrackedFile(change.path) }
                        }
                    }
                }
            }
            menu.addItem(.separator())
            add("在 Finder 中显示", "Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }
            add("复制路径", "Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(file.path, forType: .string) }
            menu.autoenablesItems = false
            return menu
        }
        @objc private func invokeMenu(_ sender: NSMenuItem) { (sender.representedObject as? FileMenuAction)?.perform() }
    }
}

private final class FileMenuAction: NSObject {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
}

final class FileOutlineView: NSOutlineView {
    var makeMenu: ((Int) -> NSMenu?)?
    var openSelection: (() -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? makeMenu?(row) : nil
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { openSelection?(); return }
        super.keyDown(with: event)
    }
}
