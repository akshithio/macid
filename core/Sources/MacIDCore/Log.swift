import Foundation

/// One log for every process that hosts the agent — the CLI under launchd or
/// the app — so there is a single place to look when unlocking misbehaves.
public enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private static let lock = NSLock()

    /// On for the CLI, where launchd captures stdout; off in the app.
    public static var echoToStdout = false

    public static func line(_ message: String) {
        let entry = "\(formatter.string(from: Date())) \(message)\n"
        lock.lock(); defer { lock.unlock() }
        if echoToStdout {
            FileHandle.standardOutput.write(Data(entry.utf8))
        }
        if let handle = try? FileHandle(forWritingTo: Paths.log) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: Paths.log, atomically: true, encoding: .utf8)
        }
    }
}
