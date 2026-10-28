import XCTest
@testable import CodeFlightApp

@MainActor
final class RunConfigurationInteractionTests: XCTestCase {
    private var workspace: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    func testQuickCommandDraftSurvivesProjectSwitchAndClose() throws {
        let model = WorkbenchModel(restoringSession: false)
        let first = Project(name: "first", path: workspace.path + "/.missing-first")
        let second = Project(name: "second", path: workspace.path + "/.missing-second")
        model.projects = [first, second]
        model.selectedProjectID = first.id
        XCTAssertTrue(model.commandText.isEmpty)
        model.commandText = "printf first-draft"
        model.selectProject(second)
        XCTAssertTrue(model.commandText.isEmpty)
        model.commandText = "printf second-draft"
        model.selectProject(first)
        XCTAssertEqual(model.commandText, "printf first-draft")
        model.selectProject(second)
        XCTAssertEqual(model.commandText, "printf second-draft")
        model.closeProject(second.id)
        XCTAssertEqual(model.commandText, "printf first-draft")
        model.closeProject(first.id)
        XCTAssertTrue(model.commandText.isEmpty)
    }

    func testSavedConfigurationRestoreDoesNotReplaceUnexecutedDraft() throws {
        let root = workspace.appendingPathComponent(".run-draft-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removeObject(forKey: "run.selected." + root.path) }
        let model = WorkbenchModel(restoringSession: false)
        let first = Project(name: "configured", path: root.path)
        let second = Project(name: "other", path: root.appendingPathComponent("missing").path)
        model.projects = [first, second]; model.selectedProjectID = first.id
        let configuration = RunConfiguration(name: "saved", command: "printf configured", workingDirectory: "")
        XCTAssertTrue(model.replaceRunConfigurations([configuration], selectedID: configuration.id, projectID: first.id))
        model.commandText = "printf not-executed"
        model.selectProject(second)
        model.selectProject(first)
        XCTAssertEqual(model.selectedRunConfigurationID, configuration.id)
        XCTAssertEqual(model.commandText, "printf not-executed")
        XCTAssertTrue(model.runningTasks.isEmpty)
        model.selectRunConfiguration(configuration)
        XCTAssertEqual(model.commandText, configuration.command, "Explicit configuration selection still applies its command")
    }

    func testBackgroundLaunchUsesTargetConfigurationDirectoryAndEnvironment() async throws {
        let model = WorkbenchModel(restoringSession: false)
        var first = Project(name: "first", path: workspace.path)
        var second = Project(name: "second", path: workspace.appendingPathComponent("CodeFlight").path)
        let front = RunConfiguration(name: "front", command: "printf wrong-project", workingDirectory: "", environment: ["GW_PROJECT": "front"])
        let back = RunConfiguration(name: "back", command: "printf '%s:%s' \"$GW_PROJECT\" \"$PWD\"", workingDirectory: "", environment: ["GW_PROJECT": "back"])
        first.runConfigurations = [front]; second.runConfigurations = [back]
        model.projects = [first, second]; model.selectedProjectID = first.id
        model.selectRunConfiguration(front)
        defer { UserDefaults.standard.removeObject(forKey: "run.selected." + first.path) }
        model.commandText = "printf front-draft"
        model.runCommand(projectID: second.id)
        let task = try XCTUnwrap(model.runningTasks[second.id]?.first)
        XCTAssertEqual(task.command, back.command)
        XCTAssertEqual(task.environment, back.environment)
        XCTAssertEqual(task.workingDirectory, second.path)
        XCTAssertEqual(task.configurationID, back.id)
        XCTAssertTrue(model.runningTasks[first.id, default: []].isEmpty)
        XCTAssertEqual(model.commandText, "printf front-draft")
        for _ in 0..<800 {
            if model.runningTasks[second.id]?.first?.isRunning == false { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.runningTasks[second.id]?.first?.exitCode, 0)
        XCTAssertEqual(model.runningTasks[second.id]?.first?.output, "back:" + second.path)
    }

    func testInvalidLaunchSnapshotsNeverCreateRunningSessionsOrExposeEnvironmentValues() {
        let model = WorkbenchModel(restoringSession: false)
        let project = Project(name: "fixture", path: workspace.path)
        model.projects = [project]; model.selectedProjectID = project.id
        for (command, directory, environment) in [
            ("printf ok", workspace.appendingPathComponent("missing-" + UUID().uuidString).path, [String: String]()),
            ("printf bad\0suffix", workspace.path, [:]),
            ("printf ok", workspace.path, ["BAD-KEY": "must-stay-private"]),
            ("printf ok", workspace.path, ["KEY": "must-stay-private\0"])
        ] {
            model.errorMessage = nil
            model.runCommand(command: command, workingDirectory: directory, environment: environment)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertFalse(model.errorMessage?.contains("must-stay-private") == true)
            XCTAssertTrue(model.runningTasks.isEmpty)
            XCTAssertFalse(model.projects[0].isRunning)
        }
        // Values are process environment strings, not shell input: quotes and
        // newlines must stay valid when supplied by a launch snapshot.
        XCTAssertNil(RunConfigurationValidation.launchError(command: "printf ok", directory: workspace.path,
            environment: ["VALUE": "'literal\nline"], language: .english))
    }

    func testInvalidEnvironmentAndDuplicateNamesCannotOverwriteSavedConfiguration() throws {
        let root = workspace.appendingPathComponent(".run-config-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removeObject(forKey: "run.selected." + root.path) }
        let m = WorkbenchModel(restoringSession: false); let p = Project(name: "fixture", path: root.path)
        m.projects = [p]; m.selectedProjectID = p.id
        let config = RunConfiguration(name: "valid", command: "printf ok", workingDirectory: "")
        XCTAssertTrue(m.replaceRunConfigurations([config], selectedID: config.id, projectID: p.id))
        let url = root.appendingPathComponent(".git-workbench/run-config.json"); let before = try Data(contentsOf: url)
        var invalid = config; invalid.environment = ["BAD-KEY": "secret-must-not-appear"]
        XCTAssertFalse(m.replaceRunConfigurations([invalid], selectedID: invalid.id, projectID: p.id))
        XCTAssertFalse(m.errorMessage?.contains("secret-must-not-appear") == true)
        var duplicate = config; duplicate.id = UUID(); duplicate.name = " valid "
        XCTAssertFalse(m.replaceRunConfigurations([config, duplicate], selectedID: config.id, projectID: p.id))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(m.projects[0].runConfigurations, [config])
        for value in ["BROKEN", "X=1\nX=2", "X=\"unterminated", "数字=1", "X=a\0b"] {
            XCTAssertNotNil(RunConfigurationValidation.environmentErrorLine(value))
        }
        let valid = "# comment\nexport X='hello world'\nTOKEN=a=b\nEMPTY=\nURL=https://example.com/a b"
        XCTAssertNil(RunConfigurationValidation.environmentErrorLine(valid))
        XCTAssertEqual(EnvironmentParser.parse(valid)["TOKEN"], "a=b")
    }
    func testSelectionSurvivesANewModelAndMissingConfigurationOpensSettings() throws {
        let root = workspace.appendingPathComponent(".run-config-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removeObject(forKey: "run.selected." + root.path) }
        let first = WorkbenchModel(restoringSession: false); let p = Project(name: "fixture", path: root.path)
        first.projects = [p]; first.selectedProjectID = p.id
        let configs = [RunConfiguration(name: "one", command: "printf one", workingDirectory: ""), RunConfiguration(name: "two", command: "printf two", workingDirectory: "")]
        XCTAssertTrue(first.replaceRunConfigurations(configs, selectedID: configs[1].id, projectID: p.id))
        let restored = WorkbenchModel(restoringSession: false)
        restored.projects = [p]; restored.selectProject(p)
        XCTAssertEqual(restored.selectedRunConfigurationID, configs[1].id)
        let empty = WorkbenchModel(restoringSession: false)
        empty.projects = [p]; empty.selectedProjectID = p.id
        empty.commandText = "printf must-not-run"
        empty.runSelectedConfiguration()
        XCTAssertTrue(empty.showRunSettings)
        XCTAssertTrue(empty.runningTasks.isEmpty)
        // A modal configuration draft must not be lost through project shortcuts.
        let other = Project(name: "other", path: root.path + "/other")
        empty.projects.append(other); empty.selectProject(other); empty.closeProject(p.id)
        XCTAssertEqual(empty.selectedProjectID, p.id)
        XCTAssertEqual(empty.projects.count, 2)
    }

    func testSavedDataRejectsDuplicateIDsAndEnvironmentEditorRoundTripsLiteralValues() throws {
        let config = RunConfiguration(name: "one", command: "printf one", workingDirectory: "")
        XCTAssertNil(RunConfigurationValidation.decodeSaved(try JSONEncoder().encode([config, config])))
        XCTAssertNil(RunConfigurationValidation.decodeSaved(Data("invalid".utf8)))
        XCTAssertNil(RunConfigurationValidation.decodeSaved(Data(repeating: 32, count: 1024 * 1024 + 1)))
        XCTAssertEqual(RunConfigurationValidation.decodeSaved(try JSONEncoder().encode([config])), [config])
        let values = ["MULTILINE": "first\nsecond\r\nthird", "QUOTE": "\"quotes\" and 'single'", "PATH_VALUE": #"C:\new\test"#, "LITERAL": #"$(touch never) `never` \n"#, "SPACE": " leading and trailing ", "EMPTY": ""]
        let text = EnvironmentParser.serialize(values)
        XCTAssertNil(RunConfigurationValidation.environmentErrorLine(text))
        XCTAssertEqual(EnvironmentParser.parse(text), values)
        var saved = config; saved.environment = values
        XCTAssertNil(RunConfigurationValidation.error([saved], environments: [saved.id: text], projectPath: workspace.path, language: .english))
        XCTAssertNotNil(RunConfigurationValidation.environmentErrorLine(#"VALUE="\u0000""#))
    }
    func testEditingSheetPreventsProjectShortcutsAndCanCancelQuit() {
        let model = WorkbenchModel(restoringSession: false)
        let first = Project(name: "first", path: "/nonexistent/first")
        let second = Project(name: "second", path: "/nonexistent/second")
        model.projects = [first, second]; model.selectedProjectID = first.id
        var quitChecks = 0
        model.confirmSheetQuit = { quitChecks += 1; return false }
        model.selectProject(second)
        model.selectAdjacentProject(offset: 1)
        model.closeProject(first.id)
        model.openProject(at: URL(fileURLWithPath: "/nonexistent/must-not-open"))
        XCTAssertEqual(model.selectedProjectID, first.id)
        XCTAssertEqual(model.projects.map(\.id), [first.id, second.id])
        model.requestApplicationQuit()
        XCTAssertEqual(quitChecks, 1)
        XCTAssertNotNil(model.confirmSheetQuit)
        XCTAssertFalse(model.quitRequestPending)
        model.confirmSheetQuit = nil
    }

}
