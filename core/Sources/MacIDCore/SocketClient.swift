import Foundation
import Darwin

/// Minimal client for the agent's unix socket.
public enum SocketClient {
    /// Sends one line and returns the one-line reply, or nil if nothing is
    /// listening or it does not answer within `timeout`.
    public static func request(_ message: String,
                               path: String = Paths.socket.path,
                               timeout: TimeInterval = 1) -> String? {
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

    /// True if some process — the app or the launchd agent — is already
    /// serving the socket.
    public static var agentIsRunning: Bool {
        guard let reply = request("STATUS") else { return false }
        return !reply.isEmpty
    }
}
