import XCTest
@testable import CodeFlightApp

final class ProjectTabTests: XCTestCase {
    @MainActor
    func testActiveTabClickPreservesEditorAndClosingChoosesAdjacentTab() {
        let defaults = UserDefaults.standard
        let recent = defaults.object(forKey: "recentProjectPaths")
        let selected = defaults.object(forKey: "selectedProjectPath")
        defer {
            if let recent { defaults.set(recent, forKey: "recentProjectPaths") } else { defaults.removeObject(forKey: "recentProjectPaths") }
            if let selected { defaults.set(selected, forKey: "selectedProjectPath") } else { defaults.removeObject(forKey: "selectedProjectPath") }
        }
        let model = WorkbenchModel(restoringSession: false)
        let prefix = "/nonexistent/git-workbench-tab-test/" + UUID().uuidString
        let a = Project(name: "a", path: prefix + "/a")
        let b = Project(name: "b", path: prefix + "/b")
        let c = Project(name: "c", path: prefix + "/c")
        let d = Project(name: "d", path: prefix + "/d")
        model.projects = [a, b, c, d]; model.selectedProjectID = b.id
        model.selectedFile = "preview.swift"; model.fileContent = "keep preview"; model.commitMessage = "draft b"
        model.gitTracking = GitBranchTracking(upstream: "origin/main", ahead: 2, behind: 3)
        model.selectProject(b)
        XCTAssertEqual(model.gitTracking?.ahead, 2)
        XCTAssertEqual(model.selectedFile, "preview.swift")
        XCTAssertEqual(model.fileContent, "keep preview")
        XCTAssertEqual(model.commitMessage, "draft b")
        model.closeProject(b.id)
        XCTAssertEqual(model.selectedProjectID, c.id)
        XCTAssertNil(model.gitTracking)
        model.selectedFile = "other.swift"; model.fileContent = "keep other"; model.commitMessage = "draft c"
        model.closeProject(a.id)
        XCTAssertEqual(model.selectedProjectID, c.id)
        XCTAssertEqual(model.selectedFile, "other.swift")
        XCTAssertEqual(model.fileContent, "keep other")
        XCTAssertEqual(model.commitMessage, "draft c")
        model.selectProject(d)
        model.closeProject(d.id)
        XCTAssertEqual(model.selectedProjectID, c.id)
        XCTAssertEqual(model.commitMessage, "draft c")
        // Closing the last tab clears preview and draft state.
        model.closeProject(c.id)
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertNil(model.selectedProjectID)
        XCTAssertEqual(model.fileContent, "")
        XCTAssertEqual(model.commitMessage, "")
        // Unknown or already closed tabs are no-ops.
        model.closeProject(b.id)
        XCTAssertNil(model.selectedProjectID)
    }
}
