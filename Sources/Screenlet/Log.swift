import Foundation

/// The host clock in nanoseconds. ScreenCaptureKit stamps frames with it, and
/// the tablet's pings are matched against it.
@inline(__always) func nowNanos() -> Int64 {
    Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
}

private let logQueue = DispatchQueue(label: "screenlet.log")
private let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

/// Writes a line to ~/Library/Logs/Screenlet.log (visible in Console) and stderr.
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

/// Runs fn on the main thread.
func later(_ fn: @escaping () -> Void) {
    DispatchQueue.main.async(execute: fn)
}

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
