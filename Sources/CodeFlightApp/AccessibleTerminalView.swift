import AppKit
import SwiftTerm

/// Expose the current screen without copying the entire scrollback or polling.
/// Keyboard input and native IME remain owned by SwiftTerm's NSTextInputClient.
@MainActor
final class WorkbenchTerminalView: LocalProcessTerminalView {
    private var notificationTask: Task<Void, Never>?

    func configureAccessibility(title: String, language: AppLanguage) {
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel(Copy.t("终端", "Terminal", language: language) + " — " + title)
        setAccessibilityHelp(Copy.t("可输入命令。辅助功能文本为当前可见终端内容。", "Enter commands with the keyboard. Accessible text contains the visible terminal screen.", language: language))
    }

    private func screenText() -> NSString {
        // The copied-row API holds SwiftTerm's terminal lock internally. Never
        // read its mutable buffer, or decode the 2,000-line history for AX.
        let rows = visibleRowsText(0..<max(0, terminalDimensions.rows))
        return rows.joined(separator: "\n") as NSString
    }

    override func accessibilityValue() -> Any? { screenText() as String }
    override func accessibilityNumberOfCharacters() -> Int { screenText().length }
    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: screenText().length)
    }
    override func accessibilityString(for range: NSRange) -> String? {
        let text = screenText()
        guard range.location != NSNotFound, range.location >= 0,
              range.length >= 0, range.location <= text.length,
              range.length <= text.length - range.location else { return nil }
        return text.substring(with: range)
    }
    override func accessibilityRange(forLine line: Int) -> NSRange {
        guard line >= 0 else { return NSRange(location: NSNotFound, length: 0) }
        let text = screenText()
        var location = 0, current = 0
        while current < line, location < text.length {
            location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
            current += 1
        }
        guard current == line, location < text.length else { return NSRange(location: NSNotFound, length: 0) }
        return text.lineRange(for: NSRange(location: location, length: 0))
    }
    override func accessibilityLine(for index: Int) -> Int {
        let text = screenText()
        guard index >= 0, index <= text.length else { return NSNotFound }
        var line = 0, location = 0
        while location < index {
            let end = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
            if end > index { break }
            location = end; line += 1
        }
        return line
    }
    override func isAccessibilitySelectorAllowed(_ selector: Selector) -> Bool {
        // Setting the output value must not pretend to edit history or send
        // commands. Assistive clients focus the terminal and type normally.
        if selector == NSSelectorFromString("setAccessibilityValue:") { return false }
        return super.isAccessibilitySelectorAllowed(selector)
    }
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func setAccessibilityFocused(_ focused: Bool) {
        if focused { window?.makeFirstResponder(self) }
    }

    override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        super.rangeChanged(source: source, startY: startY, endY: endY)
        scheduleAccessibilityChange()
    }
    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        scheduleAccessibilityChange()
    }
    private func scheduleAccessibilityChange() {
        guard NSWorkspace.shared.isVoiceOverEnabled, window?.isVisible == true,
              notificationTask == nil else { return }
        // Coalesce output bursts for VoiceOver. No timer or screen copy runs
        // when VoiceOver is off, and notifications never announce every byte.
        notificationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self else { return }
            self.notificationTask = nil
            if self.window?.isVisible == true {
                NSAccessibility.post(element: self, notification: .valueChanged)
            }
        }
    }
}
