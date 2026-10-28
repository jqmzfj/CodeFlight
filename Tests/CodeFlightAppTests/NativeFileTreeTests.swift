import AppKit
import SwiftUI
import XCTest
@testable import CodeFlightApp

@MainActor
final class NativeFileTreeTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".native-tree-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Nested"), withIntermediateDirectories: true)
        try "let a = 1".write(to: root.appendingPathComponent("Sources/file.swift"), atomically: true, encoding: .utf8)
        try "{}".write(to: root.appendingPathComponent("Sources/Nested/config.json"), atomically: true, encoding: .utf8)
        return root
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Directory loading did not finish")
    }
    func testDirectoriesAreLoadedOnExpansionAndCollapsedContentsAreReleased() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = FileTreeData()
        data.replace(FileTreeLoader.load(url: root))
        let sources = try XCTUnwrap(data.roots.first)
        XCTAssertNil(sources.children)
        XCTAssertEqual(data.pendingReadCount, 0)
        data.load(sources); data.load(sources)
        XCTAssertEqual(data.pendingReadCount, 1)
        XCTAssertTrue(data.isLoading(sources.file.path), "An expanded directory should expose its pending read state")
        try await waitUntil { sources.children != nil }
        XCTAssertFalse(data.isLoading(sources.file.path))
        XCTAssertEqual(sources.children?.count, 2)
        let nested = try XCTUnwrap(sources.children?.first)
        XCTAssertNil(nested.children, "Expanding a parent must not read its descendants")
        data.load(nested)
        try await waitUntil { nested.children != nil }
        XCTAssertEqual(nested.children?.first?.file.name, "config.json")
        data.collapse(sources)
        XCTAssertNil(sources.children)
        XCTAssertEqual(data.pendingReadCount, 0)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Sources/file.swift"))
        data.load(sources)
        try await waitUntil { sources.children != nil }
        XCTAssertEqual(sources.children?.count, 1, "Reopening a folder must reflect disk changes")
    }
    func testCollapsedOrReplacedReadsCannotRepopulateObsoleteTree() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = FileTreeData()
        data.replace(FileTreeLoader.load(url: root))
        let obsolete = try XCTUnwrap(data.roots.first)
        var callbacks = 0
        data.didLoad = { _ in callbacks += 1 }
        data.load(obsolete)
        data.collapse(obsolete)
        data.load(obsolete)
        data.replace([])
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(obsolete.children)
        XCTAssertTrue(data.roots.isEmpty)
        XCTAssertEqual(data.pendingReadCount, 0)
        XCTAssertEqual(callbacks, 0)
    }
    func testDirectoryLimitNoticeCannotOpenAFileOrExposeFileActions() {
        let files = (0..<FileTreeLoader.maxEntriesPerDirectory).map {
            FileItem(name: "file-" + String($0), icon: "doc", children: [], path: "/qa/" + String($0), isDirectory: false)
        }
        let model = WorkbenchModel(restoringSession: false)
        let tree = NativeFileTree(items: files, model: model, search: "", expandedItems: .constant([]))
        let coordinator = NativeFileTree.Coordinator(tree)
        let outline = FileOutlineView()
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")))
        outline.dataSource = coordinator; outline.delegate = coordinator; coordinator.outline = outline
        coordinator.update(tree)
        let last = outline.numberOfRows - 1
        guard let notice = outline.item(atRow: last) as? FileTreeEntry else { XCTFail("Missing directory limit notice"); return }
        XCTAssertTrue(notice.isLimitNotice)
        XCTAssertFalse(coordinator.outlineView(outline, shouldSelectItem: notice))
        XCTAssertNil(coordinator.menu(row: last))
        outline.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
        coordinator.openSelection()
        XCTAssertTrue(model.selectedFile.isEmpty)
    }
    func testNativeOutlinePreservesDirectorySelectionAndFileMenus() async throws {
        _ = NSApplication.shared
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkbenchModel(restoringSession: false)
        let project = Project(name: "native-qa", path: root.path)
        model.projects = [project]; model.selectedProjectID = project.id
        let files = FileTreeLoader.load(url: root)
        var expanded = Set<String>()
        let tree = NativeFileTree(items: files, model: model, search: "", expandedItems: Binding(get: { expanded }, set: { expanded = $0 }))
        let coordinator = NativeFileTree.Coordinator(tree)
        let outline = FileOutlineView(frame: NSRect(x: 0, y: 0, width: 280, height: 240))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.dataSource = coordinator; outline.delegate = coordinator
        coordinator.outline = outline
        coordinator.update(tree)
        XCTAssertEqual(outline.numberOfRows, 1)
        let sources = try XCTUnwrap(outline.item(atRow: 0) as? FileTreeEntry)
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        outline.expandItem(sources)
        try await waitUntil { outline.numberOfRows == 3 }
        XCTAssertTrue(expanded.contains(sources.file.path))
        coordinator.update(tree)
        XCTAssertEqual(outline.selectedRow, 0, "Updating the preview must not steal directory keyboard focus")
        outline.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        XCTAssertEqual(model.selectedFile, root.appendingPathComponent("Sources/file.swift").path)
        let menu = try XCTUnwrap(coordinator.menu(row: 2))
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title), ["打开文件", "在 Finder 中显示", "复制路径"])
        outline.collapseItem(sources)
        XCTAssertNil(sources.children)
        XCTAssertFalse(expanded.contains(sources.file.path))
        coordinator.data.cancel()
    }
}
