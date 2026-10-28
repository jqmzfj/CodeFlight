import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var backdrop: WorkbenchBackdrop
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var updateState: UpdateState = .idle

    private enum UpdateState {
        case idle, checking, current, available(CodeFlightRelease, URL), failed(String)
    }

    private func text(_ zh: String, _ en: String) -> String { Copy.t(zh, en, language: model.language) }
    private var isCheckingForUpdates: Bool {
        if case .checking = updateState { return true }
        return false
    }
    private var backgroundSelection: Binding<String> {
        Binding(get: {
            switch model.background {
            case .plain: return "plain"
            case .aurora: return "aurora"
            case .image: return "image"
            }
        }, set: { value in
            switch value {
            case "plain": model.background = .plain
            case "aurora": model.background = .aurora
            default: model.chooseBackgroundImage()
            }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(text("外观与语言", "Appearance & Language"), systemImage: "paintbrush")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { checkForUpdates() } label: {
                    Label(text("检查更新", "Check for updates"), systemImage: "arrow.down.circle")
                }.controlSize(.small).disabled(isCheckingForUpdates)
                Button(text("关闭", "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(text("外观", "Appearance")) {
                        setting(text("主题", "Theme")) {
                            Picker(text("主题", "Theme"), selection: $model.theme) {
                                Text(text("跟随系统", "System")).tag(AppTheme.system)
                                Text(text("浅色", "Light")).tag(AppTheme.light)
                                Text(text("深色", "Dark")).tag(AppTheme.dark)
                            }.pickerStyle(.segmented).labelsHidden()
                        }
                        Divider()
                        setting(text("背景", "Background")) {
                            Picker(text("背景", "Background"), selection: backgroundSelection) {
                                Text(text("纯色", "Plain")).tag("plain")
                                Text(text("渐变", "Gradient")).tag("aurora")
                                Text(text("图片", "Image")).tag("image")
                            }.pickerStyle(.segmented).labelsHidden()
                        }
                        if case .image(let url) = model.background {
                            HStack(spacing: 12) {
                                Label(url.lastPathComponent, systemImage: "photo")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle).help(url.path)
                                Spacer(minLength: 0)
                                Button(text("更换图片…", "Change image…")) { model.chooseBackgroundImage() }
                                    .controlSize(.small).fixedSize()
                            }
                            if backdrop.state == .loading(url) {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(text("正在加载背景图片…", "Loading background image…"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } else if backdrop.state == .failed(url) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(text("图片无法读取，可能已移动、删除或格式不受支持。", "The image could not be read. It may have moved, been deleted, or use an unsupported format."), systemImage: "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack {
                                        Button(text("重试", "Retry")) { Task { await backdrop.load(url) } }
                                        Button(text("使用纯色", "Use plain background")) { model.background = .plain }
                                    }.controlSize(.small)
                                }
                            }
                        }
                    }
                    section(text("语言", "Language")) {
                        Picker(text("界面语言", "Interface language"), selection: $model.language) {
                            ForEach(AppLanguage.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    section(text("编辑器", "Editor")) {
                        setting(text("代码字号", "Editor font size")) {
                            HStack(spacing: 12) {
                                Slider(value: $model.editorFontSize, in: 11...20, step: 1)
                                Text("\(Int(model.editorFontSize)) pt")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 46, alignment: .trailing)
                                Button(text("默认", "Default")) { model.editorFontSize = 13 }
                                    .controlSize(.small)
                            }
                        }
                        Text(text("用于代码预览和冲突编辑器，修改后立即生效。", "Applies to code previews and conflict editors immediately."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    section(text("布局", "Layout")) {
                        HStack {
                            Text(text("窗口布局", "Window layout")).font(.system(size: 12))
                            Spacer()
                            Button(text("恢复默认布局", "Reset layout")) { WorkbenchLayout.reset() }
                        }
                        Text(text("拖动分隔线调节大小，双击恢复当前区域；选中分隔线后可用方向键微调。", "Drag dividers to resize, double-click to reset a pane, or focus a divider and use arrow keys."))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    section(text("更新", "Updates")) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("CodeFlight").font(.system(size: 12, weight: .medium))
                                Text(text("当前版本 \(CodeFlightUpdater.currentVersion)", "Current version \(CodeFlightUpdater.currentVersion)"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            switch updateState {
                            case .checking:
                                ProgressView().controlSize(.small)
                            case .available(let release, let url):
                                Button(text("下载 \(release.tagName)", "Download \(release.tagName)")) { openURL(url) }
                                    .buttonStyle(.borderedProminent).controlSize(.small)
                            default:
                                Button(text("检查更新", "Check for updates")) { checkForUpdates() }
                                    .controlSize(.small)
                            }
                        }
                        if case .current = updateState {
                            Text(text("已是最新版本。", "You are up to date.")).font(.caption).foregroundStyle(.secondary)
                        } else if case .failed(let message) = updateState {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        } else if case .available(let release, _) = updateState, let body = release.body, !body.isEmpty {
                            Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Text(text("更新来自 GitHub Releases，下载和安装由你确认。", "Updates come from GitHub Releases and require your confirmation to download and install."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text(text("修改会自动保存", "Changes save automatically"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(text("完成", "Done")) { dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 460, idealWidth: 520, maxWidth: .infinity,
               minHeight: 360, idealHeight: 570, maxHeight: .infinity)
        .resizableSheet(minimumWidth: 460, minimumHeight: 360, language: model.language)
        .onChange(of: model.language) { _ in model.persistPreferences() }
        .onChange(of: model.theme) { _ in model.persistPreferences() }
        .onChange(of: model.background) { _ in model.persistPreferences() }
        .onChange(of: model.editorFontSize) { value in
            model.editorFontSize = min(20, max(11, value))
            model.persistPreferences()
        }
    }

    private func checkForUpdates() {
        updateState = .checking
        Task {
            do {
                switch try await CodeFlightUpdater.check() {
                case .current: updateState = .current
                case .available(let release, let url): updateState = .available(release, url)
                }
            } catch {
                updateState = .failed(error.localizedDescription)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14, content: content)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07)))
        }
    }

    private func setting<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }
}
