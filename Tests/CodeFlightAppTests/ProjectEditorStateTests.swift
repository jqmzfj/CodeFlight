import XCTest
@testable import CodeFlightApp

@MainActor
final class ProjectEditorStateTests: XCTestCase {
    func testBookmarksReloadDiskAndPreserveExplicitlyClosedPreview() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".editor-state-qa-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sample.swift")
        try "let value = 1".write(to: file, atomically: true, encoding: .utf8)
        let project = Project(name: "editor-qa", path: root.path)
        let model = WorkbenchModel(restoringSession: false)
        model.projects = [project]; model.selectedProjectID = project.id
        model.openFilePath(file.path)
        model.rememberProjectEditor()
        XCTAssertEqual(model.projectEditorLocations[project.id], .file(file.path))
        model.closePreview()
        try "let value = 200".write(to: file, atomically: true, encoding: .utf8)
        model.restoreProjectEditor(project)
        for _ in 0..<200 {
            if model.fileContent == "let value = 200" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.fileContent, "let value = 200")
        model.closePreview(); model.rememberProjectEditor()
        XCTAssertEqual(model.projectEditorLocations[project.id], .closed)
        model.previewWasClosed = false
        model.restoreProjectEditor(project)
        model.openInitialPreview(project, tree: FileTreeLoader.load(url: root))
        XCTAssertTrue(model.previewWasClosed)
        XCTAssertTrue(model.selectedFile.isEmpty)
    }

    func testDiffAndHistoryMetadataNeverOverrideNewSelection() throws {
        let project = Project(name: "qa", path: "/nonexistent/editor-qa")
        let model = WorkbenchModel(restoringSession: false)
        model.projects = [project]; model.selectedProjectID = project.id
        model.selectedFile = project.path + "/old.swift"
        model.diffContent = "diff"; model.diffIsStaged = true
        model.rememberProjectEditor()
        XCTAssertEqual(model.projectEditorLocations[project.id], .diff(path: "old.swift", staged: true))
        model.selectedFile = project.path + "/new.swift"
        model.restoreProjectDiff(project, changes: [])
        XCTAssertEqual(model.selectedFile, project.path + "/new.swift")
        model.historyCommit = "abc123"
        model.rememberProjectEditor()
        XCTAssertEqual(model.projectEditorLocations[project.id], .commit(hash: "abc123", path: "new.swift"))
    }
}
