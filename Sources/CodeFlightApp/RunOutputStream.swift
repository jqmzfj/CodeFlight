import Foundation

struct RunOutputSnapshot: Sendable {
    let text: String
    let truncated: Bool
}

/// Plain log semantics for common ANSI output. State spans pipe chunks; OSC
/// payloads and control sequences are discarded without accumulating them.
struct RunLogBuffer {
    private enum Mode { case text, escape, csi, osc, oscEscape }
    private var mode = Mode.text
    private var argument = ""
    private var history = ""
    private var line = ""
    private var historyCount = 0
    private var lineCount = 0
    private var carriageReturn = false
    private(set) var truncated = false
    let limit: Int

    init(limit: Int = 12_000) { self.limit = max(1, limit) }
    var snapshot: RunOutputSnapshot {
        let text = history + line
        return RunOutputSnapshot(text: String(String.UnicodeScalarView(text.unicodeScalars.suffix(limit))), truncated: truncated)
    }

    mutating func clear() {
        history = ""; line = ""; historyCount = 0; lineCount = 0
        carriageReturn = false; truncated = false
    }

    mutating func append(_ text: String) {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch mode {
            case .escape:
                switch value {
                case 0x5B: mode = .csi; argument = ""
                case 0x5D, 0x50, 0x5E, 0x5F: mode = .osc
                case 0x1B: break
                default: mode = .text
                }
            case .csi:
                if (0x40...0x7E).contains(value) {
                    if scalar == "K", argument == "2" || (argument.isEmpty && carriageReturn) {
                        line = ""; lineCount = 0
                    }
                    argument = ""; mode = .text
                } else if value == 0x1B { mode = .escape; argument = "" }
                else if argument.utf8.count < 32 { argument.unicodeScalars.append(scalar) }
            case .osc:
                if value == 7 { mode = .text }
                else if value == 0x1B { mode = .oscEscape }
            case .oscEscape:
                if value == 0x5C || value == 7 { mode = .text }
                else if value != 0x1B { mode = .osc }
            case .text:
                switch value {
                case 0x1B: mode = .escape
                case 0x0D: carriageReturn = true
                case 0x0A:
                    history += line + "\n"; historyCount += lineCount + 1
                    line = ""; lineCount = 0; carriageReturn = false
                case 8:
                    if !line.isEmpty { line.unicodeScalars.removeLast(); lineCount -= 1 }
                case 9: appendScalar(scalar)
                case 0..<32, 127: break
                default: appendScalar(scalar)
                }
            }
            if historyCount + lineCount > limit + 256 { trim() }
        }
        if historyCount + lineCount > limit { truncated = true }
    }

    private mutating func appendScalar(_ scalar: Unicode.Scalar) {
        if carriageReturn { line = ""; lineCount = 0; carriageReturn = false }
        line.unicodeScalars.append(scalar); lineCount += 1
    }
    private mutating func trim() {
        guard historyCount + lineCount > limit else { return }
        truncated = true
        if lineCount > limit {
            line = String(String.UnicodeScalarView(line.unicodeScalars.suffix(limit)))
            lineCount = limit
        }
        let remaining = limit - lineCount
        if historyCount > remaining {
            history = String(String.UnicodeScalarView(history.unicodeScalars.suffix(remaining)))
            historyCount = remaining
        }
    }
}

/// At most one pending main-queue refresh per session, with bounded retained
/// text even when the UI cannot keep up. Completion invalidates queued refreshes.
final class RunOutputStream: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = RunLogBuffer()
    private var scheduled = false
    private var closed = false
    private var receivedOutput = false
    private var cleared = false
    private let delivery: @MainActor @Sendable (RunOutputSnapshot) -> Void

    init(delivery: @escaping @MainActor @Sendable (RunOutputSnapshot) -> Void) { self.delivery = delivery }

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        lock.lock()
        guard !closed else { lock.unlock(); return }
        receivedOutput = true; buffer.append(text)
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, let snapshot = self.takePending() else { return }
                self.delivery(snapshot)
            }
        }
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer.clear(); cleared = true
    }
    func finish(fallback: String) -> RunOutputSnapshot {
        lock.lock(); defer { lock.unlock() }
        if !receivedOutput && !cleared { buffer.append(fallback) }
        closed = true
        return buffer.snapshot
    }
    private func takePending() -> RunOutputSnapshot? {
        lock.lock(); defer { lock.unlock() }
        scheduled = false
        return closed ? nil : buffer.snapshot
    }
}
