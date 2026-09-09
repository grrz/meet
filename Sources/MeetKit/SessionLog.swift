import Foundation

/// Serializes writes to a session's pipeline log file.
///
/// Two independent writers can target the same log: `RecordingSession`
/// appends recorder lifecycle events (device-change rebuilds, rebuild
/// failures) from the recorders' `onEvent` closures, and `Pipeline` appends
/// its own processing-stage messages once the session moves past recording.
/// `open`/`seek-to-end`/`write`/`close` is not atomic, so without a shared
/// lock two concurrent writers can interleave and produce a torn line.
enum SessionLog {
    static let lock = NSLock()

    /// Appends a timestamped `[ISO8601] message` line to the log file at
    /// `url`, creating the file if it doesn't exist yet.
    static func append(_ message: String, to url: URL) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            handle.write(line.data(using: .utf8)!)
            _ = try? handle.close()
        } else {
            FileManager.default.createFile(atPath: url.path,
                                           contents: line.data(using: .utf8))
        }
    }
}
