// Standalone component benchmark, compiled by measure-preview-performance.sh.
// This is not a cold disk benchmark or a measurement of UI input latency.
// Production preview implementation is compiled directly, not duplicated here.
import AppKit
import Foundation
import Darwin

enum AppLanguage { case chinese, english }
enum Copy { static func t(_ zh: String, _ en: String, language: AppLanguage) -> String { language == .chinese ? zh : en } }

@main struct PreviewProbe {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let file = CommandLine.arguments[1]
        func milliseconds<T>(_ block: () -> T) -> (T, Double) {
            let start = DispatchTime.now().uptimeNanoseconds
            let value = block()
            return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        func residentMB() -> Double {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
            }
            return status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
        }
        var result: [String: Any] = ["file": URL(fileURLWithPath: file).lastPathComponent, "bytes": FilePreviewReader.fileSize(path: file), "startMB": residentMB()]
        let (preview, readMS) = milliseconds { FilePreviewReader.read(path: file) }
        result["readMS"] = readMS
        guard preview.kind == .text else {
            result["nonText"] = true
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)); return
        }
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let cell = ("0" as NSString).size(withAttributes: [.font: font]).width
        if CommandLine.arguments.contains("--cache") {
            let cache = PreparedPreviewCache()
            let coldStart = DispatchTime.now().uptimeNanoseconds
            let cold = await cache.document(file: file, source: preview.text, fontName: font.fontName, cellWidth: cell)
            result["cacheColdMS"] = Double(DispatchTime.now().uptimeNanoseconds - coldStart) / 1_000_000
            _ = await cache.document(file: file + ".other", source: "let other = 1", fontName: font.fontName, cellWidth: cell)
            let revisitStart = DispatchTime.now().uptimeNanoseconds
            let revisit = await cache.document(file: file, source: preview.text, fontName: font.fontName, cellWidth: cell)
            result["cacheRevisitMS"] = Double(DispatchTime.now().uptimeNanoseconds - revisitStart) / 1_000_000
            result["cacheReused"] = cold?.id == revisit?.id
            result["cacheResidentMB"] = residentMB()
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
            return
        }
        let language = URL(fileURLWithPath: file).pathExtension.lowercased()
        let components = CommandLine.arguments.contains("--prepare-components")
        let (document, prepareMS) = milliseconds { PreparedCodeDocument.prepare(preview.text, fontName: font.fontName, cellWidth: cell, language: components ? "" : language) }
        if components {
            let (index, syntaxMS) = milliseconds { CodeSyntaxIndex.prepare(document.text, language: language) }
            result["syntaxPrepareMS"] = syntaxMS
            result["syntaxTokens"] = index.tokens.count
            result["prepareComponentsExperiment"] = true
        }
        result["prepareMS"] = prepareMS; result["lines"] = document.offsets.count
        result["preparedMB"] = residentMB()
        let scroll = NativeTextSurface.makeScrollView()
        let container = CodePreviewContainer(scroll: scroll)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        container.setFrameSize(NSSize(width: 900, height: 600)); container.layoutSubtreeIfNeeded()
        let coordinator = NativeTextSurface.Coordinator(); coordinator.attach(scroll)
        func paint() {
            container.layoutSubtreeIfNeeded()
            if let bitmap = container.bitmapImageRepForCachingDisplay(in: container.bounds) { container.cacheDisplay(in: container.bounds, to: bitmap) }
        }
        // Diagnostic only: compare bounded font fixing with the rejected
        // document-wide pass. Include its cost in each measured jump.
        func fixVisibleFonts() {
            guard CommandLine.arguments.contains("--fix-visible-fonts"), !document.offsets.isEmpty else { return }
            let first = max(0, Int((scroll.contentView.bounds.minY - 12) / CodeScrollView.lineHeight) - 1)
            let last = min(document.offsets.count, first + Int(ceil(scroll.contentView.bounds.height / CodeScrollView.lineHeight)) + 4)
            guard first < last else { return }
            let end = last < document.offsets.count ? document.offsets[last] : (document.text as NSString).length
            (scroll.documentView as? NSTextView)?.textStorage?.fixFontAttribute(in: NSRange(location: document.offsets[first], length: end - document.offsets[first]))
        }
        if CommandLine.arguments.contains("--fix-visible-fonts") { result["visibleFontFixExperiment"] = true }
        let (_, installMS) = milliseconds { autoreleasepool { coordinator.update(document, language: "swift", search: ""); paint() } }
        result["installPaintMS"] = installMS; result["installedMB"] = residentMB()
        // Diagnostic only: full font fixing expands storage substantially.
        // Never enable this in the production preview or normal benchmark.
        if CommandLine.arguments.contains("--fix-fonts") {
            result["fontFixExperiment"] = true
            let (_, fixMS) = milliseconds {
                (scroll.documentView as? NSTextView)?.textStorage?.fixFontAttribute(in: NSRange(location: 0, length: (document.text as NSString).length))
            }
            result["fixFontsMS"] = fixMS
            result["fixedFontsMB"] = residentMB()
        }
        if CommandLine.arguments.contains("--profile-jumps") {
            result["profileJumps"] = true // Later middlePaintMS is a warm revisit.
            print("READY")
            fflush(stdout)
            _ = readLine()
            for fraction in [0.5, 0.25, 0.75, 0.1, 0.9, 0.33, 0.66] {
                autoreleasepool {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.textHeight * fraction))
                    coordinator.highlight(); paint()
                }
            }
        }
        let (_, middleMS) = milliseconds { autoreleasepool { scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.textHeight / 2)); fixVisibleFonts(); coordinator.highlight(); paint() } }
        result["middlePaintMS"] = middleMS
        let (_, endMS) = milliseconds { autoreleasepool { scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, scroll.textHeight - scroll.contentView.bounds.height))); fixVisibleFonts(); coordinator.highlight(); paint() } }
        result["endPaintMS"] = endMS; result["residentMB"] = residentMB()
        if CommandLine.arguments.contains("--scroll-bursts") {
            // Isolate repeat viewport notifications within the same rows.
            // Keep painting included; this is still a component measurement,
            // not event-to-screen latency or an OS scroll-event simulation.
            let base = max(0, scroll.textHeight / 2)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: base))
            coordinator.highlight(); paint()
            let (_, burstMS) = milliseconds {
                for tick in 0..<120 {
                    autoreleasepool {
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: base + CGFloat(tick % 8) / 4))
                        coordinator.highlight(); paint()
                    }
                }
            }
            result["sameRowsScrollPaint120MS"] = burstMS
            result["scrollBurstExperiment"] = true
            result["afterBurstMB"] = residentMB()
        }
        coordinator.detach()
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
