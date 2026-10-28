import Foundation

/// Remember navigation, never a second copy of project file contents.
enum ProjectEditorLocation: Equatable {
    case closed
    case file(String)
    case diff(path: String, staged: Bool)
    case commit(hash: String, path: String)
}

extension WorkbenchModel {
    func rememberProjectEditor() {
        guard let project = selectedProject else { return }
        let prefix = URL(fileURLWithPath: project.path).standardizedFileURL.path + "/"
        guard !selectedFile.isEmpty, selectedFile.hasPrefix(prefix) else {
            projectEditorLocations[project.id] = previewWasClosed ? .closed : nil
            return
        }
        let relative = String(selectedFile.dropFirst(prefix.count))
        if let hash = historyCommit {
            projectEditorLocations[project.id] = .commit(hash: hash, path: relative)
        } else if !diffContent.isEmpty && conflictDocument == nil {
            projectEditorLocations[project.id] = .diff(path: relative, staged: diffIsStaged)
        } else {
            projectEditorLocations[project.id] = .file(selectedFile)
        }
    }

    func restoreProjectEditor(_ project: Project) {
        switch projectEditorLocations[project.id] {
        case .closed: previewWasClosed = true
        case .file(let path):
            if FileManager.default.fileExists(atPath: path) { openFilePath(path) }
        case .commit(let hash, let path): openCommitDiff(hash, file: path)
        case .diff, .none: break // A diff must be checked against fresh Git status.
        }
    }

    func openInitialPreview(_ project: Project, tree: [FileItem]) {
        guard !previewWasClosed, selectedFile.isEmpty else { return }
        if case .diff = projectEditorLocations[project.id] { return }
        if let first = tree.first(where: { !$0.isDirectory }) { openFilePath(first.path) }
    }

    func restoreProjectDiff(_ project: Project, changes: [GitChange]) {
        guard !previewWasClosed, selectedFile.isEmpty,
              case .diff(let path, let staged) = projectEditorLocations[project.id] else { return }
        if let change = changes.first(where: { $0.path == path }), staged ? change.isStaged : change.isUnstaged {
            openDiff(change, staged: staged)
        } else {
            let file = URL(fileURLWithPath: project.path).appendingPathComponent(path).path
            if FileManager.default.fileExists(atPath: file) { openFilePath(file) }
        }
    }
}
