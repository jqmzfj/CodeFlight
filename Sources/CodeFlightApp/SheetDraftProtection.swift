import SwiftUI
import AppKit

/// Keeps a destructive navigation pending until the user chooses to discard.
/// Normal selection can bypass this when the form retains its draft in place.
@MainActor
final class SheetDraftGuard: ObservableObject {
    @Published var isPresented = false
    private var pending: (() -> Void)?

    func request(dirty: Bool, action: @escaping () -> Void) {
        guard !isPresented else { return }
        if dirty { pending = action; isPresented = true }
        else { action() }
    }
    func cancel() { pending = nil; isPresented = false }
    func discard() {
        let action = pending
        cancel()
        action?()
    }
    func confirmQuit(dirty: Bool, context: String, language: AppLanguage, dismiss: () -> Void) -> Bool {
        guard dirty else { dismiss(); return true }
        let alert = NSAlert()
        alert.messageText = Copy.t("放弃未保存的修改并退出？", "Discard unsaved changes and quit?", language: language)
        alert.informativeText = context
        alert.addButton(withTitle: Copy.t("继续编辑", "Keep Editing", language: language)).keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: Copy.t("放弃并退出", "Discard and Quit", language: language))
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        cancel(); dismiss(); return true
    }
}

private struct SheetDraftProtection: ViewModifier {
    @ObservedObject var model: WorkbenchModel
    @ObservedObject var protection: SheetDraftGuard
    @Environment(\.dismiss) private var dismiss
    let isDirty: () -> Bool
    let isBusy: () -> Bool
    let context: () -> String

    func body(content: Content) -> some View {
        content
            .interactiveDismissDisabled(isDirty() || isBusy())
            .alert(Copy.t("放弃未保存的修改？", "Discard unsaved changes?", language: model.language), isPresented: $protection.isPresented) {
                Button(Copy.t("继续编辑", "Keep Editing", language: model.language), role: .cancel) { protection.cancel() }
                Button(Copy.t("放弃修改", "Discard Changes", language: model.language), role: .destructive) { protection.discard() }
            } message: { Text(context()) }
            .onAppear {
                model.confirmSheetQuit = {
                    protection.confirmQuit(dirty: isDirty(), context: context(), language: model.language, dismiss: { dismiss() })
                }
            }
            .onDisappear { model.confirmSheetQuit = nil; protection.cancel() }
    }
}

extension View {
    func protectDraft(using protection: SheetDraftGuard, model: WorkbenchModel,
                      dirty: @escaping () -> Bool, busy: @escaping () -> Bool,
                      context: @escaping () -> String) -> some View {
        modifier(SheetDraftProtection(model: model, protection: protection, isDirty: dirty, isBusy: busy, context: context))
    }
}
