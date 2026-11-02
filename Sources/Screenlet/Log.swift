import Foundation

/// Returns the monotonic raw host clock in nanoseconds.
///
/// Used for ScreenCaptureKit frame presentation timestamps and round-trip ping latency measurements.
@inline(__always) func nowNanos() -> Int64 {
    Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
}

private let logQueue = DispatchQueue(label: "screenlet.log")
private let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

/// Writes a timestamped log entry to standard error and `~/Library/Logs/Screenlet.log`.
func log(_ items: Any...) {
    let line = "\(stamp.string(from: Date())) " + items.map { "\($0)" }.joined(separator: " ") + "\n"
    logQueue.async {
        FileHandle.standardError.write(line.data(using: .utf8)!)
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Screenlet.log")
        if let file = try? FileHandle(forWritingTo: url) {
            file.seekToEndOfFile()
            file.write(line.data(using: .utf8)!)
            try? file.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }
}

/// Dispatches a closure asynchronously onto the main dispatch queue.
func later(_ fn: @escaping () -> Void) {
    DispatchQueue.main.async(execute: fn)
}

/// Generic error representation encapsulating a localized failure message.
struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
