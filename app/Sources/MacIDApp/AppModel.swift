import Foundation
import SwiftUI
import MacIDCore

/// Shared state for the menu bar UI.
///
/// The app is deliberately a *controller*, not a second implementation: the
/// agent running under launchd is what actually unlocks the Mac. Everything
/// here reads the same files and the same socket the agent uses, so what you
/// see in the menu is what PAM will see at the lock screen.
@MainActor
final class AppModel: ObservableObject {

    enum AgentState: Equatable {
        case running
        case notRunning
        case unknown

        var label: String {
            switch self {
            case .running: return "running"
            case .notRunning: return "not running"
            case .unknown: return "unknown"
            }
        }
    }

    @Published var enrolledSamples: Int = 0
    @Published var agent: AgentState = .unknown
    @Published var pamInstalled = false
    @Published var screenLocked = false
    @Published var config = Config.load()

    var isEnrolled: Bool { enrolledSamples > 0 }

    /// Everything in place and the lock screen actually wired up.
    var isFullyArmed: Bool { isEnrolled && agent == .running && pamInstalled }

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        enrolledSamples = (try? Enrollment.load().count) ?? 0
        screenLocked = LockMonitor.isLocked
        config = Config.load()
        pamInstalled = pamStackContainsMacID()
        agent = probeAgent()
    }

    /// Ask the agent's own socket whether it is alive. A STATUS request is
    /// read-only — unlike VERIFY it does not consume the unlock token, so the
    /// menu refreshing every few seconds can never eat an unlock.
    private func probeAgent() -> AgentState {
        guard FileManager.default.fileExists(atPath: Paths.socket.path) else {
            return .notRunning
        }
        guard let reply = SocketClient.request("STATUS") else { return .notRunning }
        return reply.hasPrefix("ARMED") || reply.hasPrefix("IDLE") ? .running : .notRunning
    }

    private func pamStackContainsMacID() -> Bool {
        guard let contents = try? String(contentsOfFile: "/etc/pam.d/screensaver_new",
                                         encoding: .utf8) else { return false }
        return contents.contains("pam_macid.so")
    }

    func save(_ newConfig: Config) {
        config = newConfig
        try? newConfig.save()
    }

    func clearEnrollment() {
        try? Enrollment.clear()
        refresh()
    }
}

/// Minimal client for the agent's unix socket.
enum SocketClient {
    static func request(_ message: String, timeout: TimeInterval = 1) -> String? {
        let path = Paths.socket.path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let payload = Array("\(message)\n".utf8)
        guard payload.withUnsafeBufferPointer({ write(fd, $0.baseAddress, $0.count) }) > 0 else {
            return nil
        }

        var buf = [UInt8](repeating: 0, count: 128)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return nil }
        return String(decoding: buf[0..<n], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
