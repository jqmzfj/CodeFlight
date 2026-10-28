import XCTest
import SwiftUI
import AppKit
@testable import CodeFlightApp

@MainActor
final class CommandPaletteTests: XCTestCase {
    func testSettingsWaitsForDismissalAndCannotReplay() {
        let model = WorkbenchModel(restoringSession: false)
        model.showCommandPalette = true
        model.requestPaletteAction(.settings)
        XCTAssertFalse(model.showCommandPalette)
        XCTAssertFalse(model.showSettings)
        model.completePaletteDismissal()
        XCTAssertTrue(model.showSettings)
        model.showSettings = false
        model.completePaletteDismissal()
        XCTAssertFalse(model.showSettings)
    }

    func testUnavailableActionsCannotDismissOrQueue() {
        let model = WorkbenchModel(restoringSession: false)
        model.showCommandPalette = true
        for command in PaletteCommand.allCases where command.requiresProject {
            model.requestPaletteAction(command)
            XCTAssertTrue(model.showCommandPalette)
            XCTAssertNil(model.pendingPaletteAction)
        }
        model.requestPaletteAction(.settings)
        XCTAssertNotNil(model.pendingPaletteAction)
    }

    func testRunUsesConfigurationFlowAndRejectsChangedProject() {
        let model = WorkbenchModel(restoringSession: false)
        let first = Project(name: "first", path: "/nonexistent/palette-first")
        let second = Project(name: "second", path: "/nonexistent/palette-second")
        model.projects = [first, second]; model.selectedProjectID = first.id
        model.commandText = "must never run a raw draft"
        model.requestPaletteAction(.run)
        model.selectedProjectID = second.id
        model.completePaletteDismissal()
        XCTAssertFalse(model.showRunSettings)
        XCTAssertTrue(model.runningTasks.isEmpty)
        model.requestPaletteAction(.run)
        XCTAssertFalse(model.showRunSettings)
        model.completePaletteDismissal()
        XCTAssertTrue(model.showRunSettings)
        XCTAssertTrue(model.runningTasks.isEmpty)
    }

    func testDismissalRechecksTerminationAndRepositoryCapabilities() {
        let model = WorkbenchModel(restoringSession: false)
        model.requestPaletteAction(.settings)
        model.isTerminating = true
        model.completePaletteDismissal()
        XCTAssertFalse(model.showSettings)
        XCTAssertNil(model.pendingPaletteAction)
        model.isTerminating = false
        let project = Project(name: "fixture", path: "/nonexistent/palette-git")
        model.projects = [project]; model.selectedProjectID = project.id
        model.isGitRepository = true
        model.requestPaletteAction(.push)
        XCTAssertNotNil(model.pendingPaletteAction)
        model.isGitRepository = false
        model.completePaletteDismissal()
        XCTAssertNil(model.pendingPaletteAction)
        XCTAssertNil(model.errorMessage)
    }

    func testFieldEditorCommandsPreserveEditingAndComposition() {
        var moves: [Int] = []; var submits = 0; var cancels = 0
        let field = PaletteQueryField(value: .constant(""), placeholder: "Search", move: { moves.append($0) }, submit: { submits += 1 }, cancel: { cancels += 1 })
        let coordinator = field.makeCoordinator()
        let control = NSTextField(); let editor = NSTextView()
        func send(_ selector: Selector) -> Bool { coordinator.control(control, textView: editor, doCommandBy: selector) }
        XCTAssertTrue(send(#selector(NSResponder.moveUp(_:))))
        XCTAssertTrue(send(#selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(send(#selector(NSResponder.insertNewline(_:))))
        XCTAssertTrue(send(#selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(moves, [-1, 1]); XCTAssertEqual(submits, 1); XCTAssertEqual(cancels, 1)
        XCTAssertFalse(send(#selector(NSResponder.moveLeft(_:))))
        XCTAssertFalse(send(#selector(NSResponder.deleteBackward(_:))))
        editor.setMarkedText("she", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(send(#selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(send(#selector(NSResponder.moveDown(_:))))
        XCTAssertFalse(send(#selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(moves, [-1, 1]); XCTAssertEqual(submits, 1); XCTAssertEqual(cancels, 1)
    }

    func testBottomToolToggleRequestRequiresProjectAndIsUniquePerPress() {
        let model = WorkbenchModel(restoringSession: false)
        model.toggleBottomTool()
        XCTAssertNil(model.bottomToolToggleRequest)

        let project = Project(name: "fixture", path: "/nonexistent/palette-tools")
        model.projects = [project]
        model.selectedProjectID = project.id
        model.toggleBottomTool()
        guard let first = model.bottomToolToggleRequest else {
            XCTFail("Expected a toggle request for an active project")
            return
        }
        model.toggleBottomTool()
        XCTAssertNotEqual(first, model.bottomToolToggleRequest)
    }
}
