import Foundation
import FltrLib

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// MARK: - RSS Measurement

func currentRSSMB() -> Double {
    #if canImport(Darwin)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    if result == KERN_SUCCESS {
        return Double(info.resident_size) / (1024.0 * 1024.0)
    }
    #endif
    var usage = rusage()
    #if canImport(Darwin)
    _ = getrusage(RUSAGE_SELF, &usage)
    #else
    _ = getrusage(__rusage_who_t(RUSAGE_SELF.rawValue), &usage)
    #endif
    #if canImport(Darwin)
    return Double(usage.ru_maxrss) / (1024.0 * 1024.0)
    #else
    return Double(usage.ru_maxrss) / 1024.0
    #endif
}

func log(_ msg: String) {
    var m = msg + "\n"
    m.withUTF8 { buf in
        _ = write(STDERR_FILENO, buf.baseAddress!, buf.count)
    }
}

// MARK: - Main

log("Starting memory test...")
log("PID: \(getpid())")
#if MmapBuffer
log("Buffer mode: mmap")
#else
log("Buffer mode: Array")
#endif

let baselineRSS = currentRSSMB()
log(String(format: "Baseline RSS: %.1f MB", baselineRSS))

let cache = ItemCache()

log("Reading from stdin...")
let startTime = Date()

// Read all lines synchronously into array first (fast)
var lines: [String] = []
lines.reserveCapacity(1_000_000)
while let line = readLine() {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
        lines.append(trimmed)
    }
}

let readElapsed = Date().timeIntervalSince(startTime)
var byteCount = 0
for line in lines { byteCount += line.utf8.count }
log("Read \(lines.count) lines, \(byteCount) bytes in \(String(format: "%.2f", readElapsed))s")
log("Registering items in cache...")

// Capture for detached task
let capturedLines = lines
lines = [] // free the original
let capturedByteCount = byteCount
let capturedBaselineRSS = baselineRSS

Task.detached {
    let regStart = Date()
    for line in capturedLines {
        await cache.append(line)
    }
    let regElapsed = Date().timeIntervalSince(regStart)
    log(String(format: "Registered in %.2fs", regElapsed))

    let afterLoadRSS = currentRSSMB()
    log(String(format: "RSS after load: %.1f MB", afterLoadRSS))

    await cache.sealAndShrink()
    try? await Task.sleep(for: .milliseconds(200))

    let afterShrinkRSS = currentRSSMB()
    let count = await cache.count()

    log("ItemCache has \(count) items")
    log(String(format: "RSS after sealAndShrink: %.1f MB", afterShrinkRSS))
    log("")
    log("=== Summary ===")
    log(String(format: "  Baseline:        %6.1f MB", capturedBaselineRSS))
    log(String(format: "  After load:      %6.1f MB", afterLoadRSS))
    log(String(format: "  After shrink:    %6.1f MB", afterShrinkRSS))
    log(String(format: "  Data loaded:     %6.1f MB (%d lines)", Double(capturedByteCount) / (1024.0 * 1024.0), count))
    log(String(format: "  Overhead ratio:  %6.2fx", afterShrinkRSS / max(1.0, Double(capturedByteCount) / (1024.0 * 1024.0))))
    log("")
    log("Ready for profiling. Press Ctrl+C to exit, or run:")
    log("  vmmap \(getpid())")
}

dispatchMain()
