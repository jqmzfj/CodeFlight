import SwiftUI
import AppKit

enum PaletteCommand: String, CaseIterable {
    case open, refresh, run, stop, stage, pull, push, settings
    var requiresProject: Bool { self != .open && self != .settings }
}

struct PaletteAction: Identifiable, Equatable {
    let id: PaletteCommand
    let title: String
    let icon: String
    let enabled: Bool
}

struct PendingPaletteAction {
    let command: PaletteCommand
    let projectID: UUID?
}

extension WorkbenchModel {
    var paletteActions: [PaletteAction] {
        func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: language) }
        let project = selectedProject != nil && !isTerminating
        let git = project && isGitRepository && !isGitBusy
        return [
            .init(id: .open, title: text("打开项目", "Open Project"), icon: "folder.badge.plus", enabled: !isTerminating),
            .init(id: .refresh, title: text("刷新当前项目", "Refresh Current Project"), icon: "arrow.clockwise", enabled: project && !isGitBusy && !isLoading),
            .init(id: .run, title: text("运行当前配置", "Run Current Configuration"), icon: "play.fill", enabled: project && selectedRunTask?.isStopping != true && !(selectedRunTask.map { restartingTaskIDs.contains($0.id) } ?? false)),
            .init(id: .stop, title: text("停止当前项目进程", "Stop Project Processes"), icon: "stop.fill", enabled: project && selectedProject?.isRunning == true),
            .init(id: .stage, title: text("暂存全部更改", "Stage All Changes"), icon: "plus.square", enabled: git && gitChanges.contains(where: \.isUnstaged) && !gitChanges.contains(where: \.isConflicted)),
            .init(id: .pull, title: text("拉取远程更新", "Pull from Remote"), icon: "arrow.down.circle", enabled: git),
            .init(id: .push, title: text("推送到远程", "Push to Remote"), icon: "arrow.up.circle", enabled: git),
            .init(id: .settings, title: text("打开设置", "Open Settings"), icon: "gearshape", enabled: !isTerminating)
        ]
    }

    func requestPaletteAction(_ command: PaletteCommand) {
        guard pendingPaletteAction == nil, paletteActions.contains(where: { $0.id == command && $0.enabled }) else { return }
        pendingPaletteAction = PendingPaletteAction(command: command, projectID: selectedProjectID)
        showCommandPalette = false
    }

    /// A new sheet or native open panel must wait for the palette to finish
    /// dismissing. Resolve capabilities again; never execute on another project.
    func completePaletteDismissal() {
        guard let pending = pendingPaletteAction else { return }
        pendingPaletteAction = nil
        guard !pending.command.requiresProject || pending.projectID == selectedProjectID,
              paletteActions.contains(where: { $0.id == pending.command && $0.enabled }) else { return }
        switch pending.command {
        case .open: addProject()
        case .refresh: if let project = selectedProject { Task { await refreshProject(project) } }
        case .run: runSelectedConfiguration()
        case .stop: stopCommand()
        case .stage: gitAction(.stageAll)
        case .pull: gitAction(.pull)
        case .push: gitAction(.push)
        case .settings: showSettings = true
        }
    }
}

struct CommandPaletteView: View {
    @ObservedObject var model: WorkbenchModel
    @State private var query = ""
    @State private var selected: PaletteCommand?
    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var actions: [PaletteAction] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.paletteActions.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
    }
    private var enabled: [PaletteCommand] { actions.filter(\.enabled).map(\.id) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(text("命令面板", "Command Palette")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(text("关闭", "Close")) { model.showCommandPalette = false }
                    .controlSize(.small).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 14).padding(.top, 12)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                PaletteQueryField(value: $query, placeholder: text("输入命令或操作", "Type a command or action"), move: move, submit: submit, cancel: { model.showCommandPalette = false })
                    .frame(height: 24)
                Text("esc").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }.padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    if actions.isEmpty {
                        Text(text("没有匹配的操作", "No matching actions")).font(.system(size: 12)).foregroundStyle(.secondary).padding(30)
                    } else {
                        VStack(spacing: 2) {
                            ForEach(actions) { action in
                                Button { model.requestPaletteAction(action.id) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: action.icon).frame(width: 20).foregroundStyle(action.enabled ? Color.accentColor : Color.secondary)
                                        Text(action.title).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 8)
                                        if selected == action.id { Image(systemName: "return").font(.caption).foregroundStyle(.secondary) }
                                    }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 9)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(selected == action.id ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(!action.enabled).opacity(action.enabled ? 1 : 0.45)
                                    .accessibilityAddTraits(selected == action.id ? .isSelected : [])
                                    .help(action.title).id(action.id)
                            }
                        }.padding(8)
                    }
                }
                .onChange(of: selected) { value in if let value { proxy.scrollTo(value) } }
            }
            Divider()
            Text(text("↑ ↓ 选择 · ↩ 执行 · esc 关闭", "↑ ↓ Select · ↩ Run · esc Close"))
                .font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .resizableSheet(minimumWidth: 440, minimumHeight: 300, language: model.language)
        .frame(idealWidth: 500, idealHeight: 430)
        .onAppear { synchronizeSelection() }
        .onChange(of: actions) { _ in synchronizeSelection() }
    }

    private func synchronizeSelection() {
        if let selected, enabled.contains(selected) { return }
        selected = enabled.first
    }
    private func move(_ offset: Int) {
        guard !enabled.isEmpty else { selected = nil; return }
        guard let selected, let index = enabled.firstIndex(of: selected) else { self.selected = enabled.first; return }
        self.selected = enabled[min(enabled.count - 1, max(0, index + offset))]
    }
    private func submit() {
        guard let selected, enabled.contains(selected) else { return }
        model.requestPaletteAction(selected)
    }
}

/// Native field-editor commands work on macOS 13 and preserve IME composition.
/// Navigation/submit/cancel selectors are consumed locally; editing falls through.
struct PaletteQueryField: NSViewRepresentable {
    @Binding var value: String
    let placeholder: String
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = InitialFocusField()
        field.isBezeled = false; field.drawsBackground = false
        // Use search semantics so system credential/code autofill does not treat
        // the command query as an ordinary form field. Icons live in SwiftUI.
        if let cell = field.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        field.maximumRecents = 0
        field.isAutomaticTextCompletionEnabled = false
        field.font = .systemFont(ofSize: 14)
        field.focusRingType = .none
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != value { field.stringValue = value }
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
    }
    final class InitialFocusField: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PaletteQueryField
        init(_ parent: PaletteQueryField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.value = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
}
