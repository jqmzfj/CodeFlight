import SwiftUI
import AppKit
import SwiftTerm
import Darwin

/// Each explicitly opened session owns one bounded terminal buffer and one PTY.
/// Views can disappear without dropping the shell or duplicating its launch.
@MainActor
final class WorkbenchTerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let view: WorkbenchTerminalView
    @Published var title: String
    @Published var ended = false
    private var closing = false
    private var cleanupFinished = false
    private var closeCompletions: [() -> Void] = []

    init(path: String, number: Int) {
        title = "Terminal \(number)"
        view = WorkbenchTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 240), font: .monospacedSystemFont(ofSize: 12, weight: .regular), options: TerminalOptions(scrollback: 2000))
        super.init()
        view.configureAccessibility(title: title, language: .chinese)
        view.processDelegate = self
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let shell = Self.shell(environment: env)
        view.startProcess(executable: shell, args: ["-l", "-i"], environment: env.map { "\($0.key)=\($0.value)" }, currentDirectory: path)
    }

    static func shell(environment: [String: String]) -> String {
        let candidate = environment["SHELL"] ?? getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) } ?? "/bin/zsh"
        return candidate.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: candidate) ? candidate : "/bin/zsh"
    }

    /// Only signal processes still belonging to this PTY's session. Foreground
    /// jobs have a different process group from the shell, so shell-only kill
    /// leaves commands running after a tab is closed.
    func close(onFinished: (() -> Void)? = nil) {
        if cleanupFinished { onFinished?(); return }
        if let onFinished { closeCompletions.append(onFinished) }
        guard !closing else { return }
        closing = true
        let sid = view.process.shellPid
        guard sid > 1, view.process.running else { finishCleanup(); return }
        Self.signalSession(sid, signal: SIGHUP)
        view.process.terminate()
        Task { @MainActor [self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            Self.signalSession(sid, signal: SIGKILL)
            // Retain the PTY until its children have been reaped.
            _ = view
            finishCleanup()
        }
    }

    private func finishCleanup() {
        cleanupFinished = true
        let callbacks = closeCompletions
        closeCompletions.removeAll()
        callbacks.forEach { $0() }
    }

    var hasRunningCommands: Bool {
        let sid = view.process.shellPid
        guard sid > 1, !ended else { return false }
        return Self.sessionPIDs(sid).contains { $0 != sid }
    }

    private static func signalSession(_ sid: pid_t, signal: Int32) {
        for pid in sessionPIDs(sid) { kill(pid, signal) }
    }

    private static func sessionPIDs(_ sid: pid_t) -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let used = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard used > 0 else { return [] }
        return pids.prefix(min(Int(used), pids.count)).filter { $0 > 1 && getsid($0) == sid }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // Shell titles can contain unbounded or control-character data.
        let clean = title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(clean)).prefix(60)
        if !text.isEmpty { self.title = String(text) }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { ended = true }
    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        ended = true
        view.feed(text: "\r\nShell launch failed: \(error)\r\n")
    }
}

@MainActor
final class WorkbenchTerminals: ObservableObject {
    @Published private(set) var sessions: [UUID: [WorkbenchTerminalSession]] = [:]
    @Published var selection: [UUID: UUID] = [:]
    private var nextNumber: [UUID: Int] = [:]
    // Removed tabs may still own a foreground job awaiting SIGKILL. Keep
    // these sessions visible to the application's termination drain gate.
    private var retiring: [UUID: WorkbenchTerminalSession] = [:]
    var hasSessions: Bool { !retiring.isEmpty || sessions.values.contains { !$0.isEmpty } }
    private func retire(_ session: WorkbenchTerminalSession) {
        retiring[session.id] = session
        let id = session.id
        session.close { [weak self] in self?.retiring.removeValue(forKey: id) }
    }
    func add(project: Project) {
        let number = nextNumber[project.id, default: 0] + 1
        nextNumber[project.id] = number
        let session = WorkbenchTerminalSession(path: project.path, number: number)
        sessions[project.id, default: []].append(session)
        selection[project.id] = session.id
    }
    func close(_ session: WorkbenchTerminalSession, project: Project, language: AppLanguage) {
        if session.hasRunningCommands {
            let alert = NSAlert()
            alert.messageText = Copy.t("关闭终端会话？", "Close terminal session?", language: language)
            alert.informativeText = Copy.t("此会话中的 Shell 和命令将停止。其他终端不受影响。", "The shell and commands in this session will stop. Other terminals stay open.", language: language)
            alert.addButton(withTitle: Copy.t("取消", "Cancel", language: language)).keyEquivalent = "\u{1b}"
            alert.addButton(withTitle: Copy.t("关闭会话", "Close Session", language: language))
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        retire(session)
        sessions[project.id]?.removeAll { $0.id == session.id }
        if selection[project.id] == session.id { selection[project.id] = sessions[project.id]?.last?.id }
    }
    func closeProject(_ id: UUID) {
        sessions.removeValue(forKey: id)?.forEach { retire($0) }
        selection.removeValue(forKey: id)
        nextNumber.removeValue(forKey: id)
    }
    func closeAll() { Array(sessions.keys).forEach(closeProject) }
}

private struct TerminalSurface: NSViewRepresentable {
    @ObservedObject var session: WorkbenchTerminalSession
    @Environment(\.colorScheme) var colorScheme
    let language: AppLanguage
    func makeNSView(context: Context) -> LocalProcessTerminalView {
        DispatchQueue.main.async { session.view.window?.makeFirstResponder(session.view) }
        return session.view
    }
    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        session.view.configureAccessibility(title: session.title, language: language)
        let appearanceName: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if view.appearance?.name != appearanceName {
            view.appearance = NSAppearance(named: appearanceName)
        }
        // Apply the palette on every update. SwiftTerm may create its backing
        // layer after the first appearance pass; guarding the whole update can
        // leave a fresh light terminal with a white-on-white prompt.
        view.nativeForegroundColor = colorScheme == .dark ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.12, alpha: 1)
        view.nativeBackgroundColor = colorScheme == .dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.99, alpha: 1)
    }
}

private struct TerminalTab: View {
    @ObservedObject var session: WorkbenchTerminalSession
    let selected: Bool
    let language: AppLanguage
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    private var displayTitle: String {
        guard language == .chinese, session.title.hasPrefix("Terminal ") else { return session.title }
        return "终端 " + String(session.title.dropFirst("Terminal ".count))
    }

    var body: some View {
        HStack(spacing: 7) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Image(systemName: session.ended ? "stop.circle" : "terminal")
                    Text(displayTitle).lineLimit(1)
                }.padding(.vertical, 7)
            }.buttonStyle(.plain)
                .accessibilityValue(selected ? Copy.t("已选中", "Selected", language: language) : "")
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9)).frame(width: 18, height: 18) }.buttonStyle(.plain)
                .help(Copy.t("关闭会话", "Close Session", language: language))
                .accessibilityLabel(Copy.t("关闭会话", "Close Session", language: language) + " " + session.title)
                .opacity(hovering || selected ? 1 : 0)
        }.font(.system(size: 11)).padding(.horizontal, 10)
            .frame(height: WorkbenchChrome.rowHeight)
            .background(selected ? WorkbenchChrome.selectedSurface : hovering ? Color.primary.opacity(0.035) : .clear)
            .overlay(alignment: .bottom) {
                if selected { Rectangle().fill(Color.accentColor.opacity(0.72)).frame(height: 2) }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct TerminalTool: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var terminals: WorkbenchTerminals
    var onHide: () -> Void = {}
    private var sessions: [WorkbenchTerminalSession] {
        model.selectedProjectID.flatMap { terminals.sessions[$0] } ?? []
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(Copy.t("终端", "Terminal", language: model.language))
                    .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12)
                Divider().frame(height: 13)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        if let project = model.selectedProject {
                            ForEach(sessions) { session in
                                TerminalTab(session: session, selected: terminals.selection[project.id] == session.id, language: model.language,
                                    select: {
                                        terminals.selection[project.id] = session.id
                                        DispatchQueue.main.async { session.view.window?.makeFirstResponder(session.view) }
                                    }, close: { terminals.close(session, project: project, language: model.language) })
                            }
                        }
                    }
                }
                Button { if let project = model.selectedProject { terminals.add(project: project) } } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).disabled(model.selectedProjectID == nil).padding(.horizontal, 12)
                    .help(Copy.t("新建终端", "New Terminal", language: model.language))
                Button(action: onHide) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 12)
                    .help(Copy.t("隐藏工具窗口", "Hide tool window", language: model.language))
            }
            .frame(height: WorkbenchChrome.rowHeight)
            .background(WorkbenchChrome.bar)
            .overlay(alignment: .bottom) { Rectangle().fill(WorkbenchChrome.quietSeparator).frame(height: 1) }
            Divider().opacity(0.4)
            if let project = model.selectedProject {
                if let session = sessions.first(where: { $0.id == terminals.selection[project.id] }) ?? sessions.last {
                    TerminalSurface(session: session, language: model.language).id(session.id)
                } else {
                    Button(Copy.t("打开终端", "Open Terminal", language: model.language)) { terminals.add(project: project) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text(Copy.t("请先打开项目", "Open a project first", language: model.language)).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.task(id: model.selectedProjectID) {
            guard !model.isTerminating, let project = model.selectedProject,
                  terminals.sessions[project.id, default: []].isEmpty else { return }
            terminals.add(project: project)
        }
        .onChange(of: model.terminalFocusRequest) { _ in
            guard let project = model.selectedProject,
                  let session = sessions.first(where: { $0.id == terminals.selection[project.id] }) ?? sessions.last else { return }
            DispatchQueue.main.async { session.view.window?.makeFirstResponder(session.view) }
        }
    }
}
