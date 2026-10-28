import Foundation
import Darwin

/// Opt-in, local diagnostics. Measures handler-to-draw, not input-device or
/// compositor presentation latency. No source text or full paths are recorded.
@MainActor
final class PreviewTrace {
    struct Sample: Codable, Sendable {
        let file: String
        let handlerToReadMS: Double
        let handlerToPreparedMS: Double
        let handlerToDrawMS: Double
        let startResidentMB: Double
        let drawResidentMB: Double
        let processLifetimePeakMB: Double
    }
    private struct Request {
        let file: String
        let start: UInt64
        let resident: Double
        var read: UInt64?
        var prepared: UInt64?
        var document: UUID?
    }
    static let shared: PreviewTrace? = {
        guard let path = ProcessInfo.processInfo.environment["CODEFLIGHT_PREVIEW_TRACE"],
              path.hasPrefix("/"), path.hasSuffix(".jsonl") else { return nil }
        let writer = TraceWriter(path: path)
        return PreviewTrace(sink: { writer.append($0) })
    }()
    private var pending: Request?
    private let now: () -> UInt64
    private let resident: () -> Double
    private let peak: () -> Double
    private let sink: (Sample) -> Void
    init(now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         resident: @escaping () -> Double = PreviewTrace.residentMB,
         peak: @escaping () -> Double = PreviewTrace.peakMB,
         sink: @escaping (Sample) -> Void) {
        self.now = now; self.resident = resident; self.peak = peak; self.sink = sink
    }
    func begin(file: String) {
        pending = Request(file: file, start: now(), resident: resident())
    }
    func didRead(file: String) {
        guard pending?.file == file else { return }
        pending?.read = now()
    }
    func didPrepare(file: String, document: UUID) {
        guard pending?.file == file, pending?.read != nil else { return }
        pending?.prepared = now(); pending?.document = document
    }
    func didDraw(document: UUID) {
        guard let request = pending, request.document == document,
              let read = request.read, let prepared = request.prepared else { return }
        pending = nil
        func ms(_ value: UInt64) -> Double { Double(value - request.start) / 1_000_000 }
        sink(Sample(file: URL(fileURLWithPath: request.file).lastPathComponent,
                    handlerToReadMS: ms(read), handlerToPreparedMS: ms(prepared),
                    handlerToDrawMS: ms(now()), startResidentMB: request.resident,
                    drawResidentMB: resident(), processLifetimePeakMB: peak()))
    }
    func cancel() { pending = nil }

    nonisolated static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }
    nonisolated static func peakMB() -> Double {
        var usage = rusage()
        return getrusage(RUSAGE_SELF, &usage) == 0 ? Double(usage.ru_maxrss) / 1_048_576 : -1
    }
}

/// Serial, bounded output off the UI thread. Only enabled by an explicit
/// environment variable; failures never interfere with opening a file.
private final class TraceWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "workbench.preview-trace", qos: .utility)
    private let path: String
    init(path: String) { self.path = path }
    func append(_ sample: PreviewTrace.Sample) {
        queue.async { [path] in
            guard var data = try? JSONEncoder().encode(sample) else { return }
            data.append(10)
            if !FileManager.default.fileExists(atPath: path) {
                guard FileManager.default.createFile(atPath: path, contents: nil) else { return }
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            do {
                let end = try handle.seekToEnd()
                guard end + UInt64(data.count) <= 1_048_576 else { return }
                try handle.write(contentsOf: data)
            } catch { return }
        }
    }
}
