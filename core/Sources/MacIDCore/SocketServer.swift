import Foundation
import Darwin

/// A recent match, held briefly so the unlock attempt that follows it can
/// redeem it without switching the camera on again.
///
/// Reading it disarms it: a PAM answer is a one-shot authorization, so one face
/// scan must not unlock a second time.
public final class VerificationState {
    public init() {}

    private let lock = NSLock()
    private var validUntil: Date?
    private var lastDistance: Float = 0

    /// How long a match stays redeemable. It covers the gap between the camera
    /// recognizing you after the display wakes and you pressing Return. A
    /// Return press after this starts a fresh look rather than trusting an old
    /// one.
    public static let lifetime: TimeInterval = 8

    public func arm(distance: Float) {
        lock.lock(); defer { lock.unlock() }
        validUntil = Date().addingTimeInterval(Self.lifetime)
        lastDistance = distance
    }

    public func disarm() {
        lock.lock(); defer { lock.unlock() }
        validUntil = nil
    }

    /// Single use: returns true at most once per successful scan.
    public func consume() -> (ok: Bool, distance: Float) {
        lock.lock(); defer { lock.unlock() }
        guard let until = validUntil, Date() < until else {
            validUntil = nil
            return (false, 0)
        }
        validUntil = nil
        return (true, lastDistance)
    }

    public var isArmed: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let until = validUntil else { return false }
        return Date() < until
    }
}

public final class SocketServer {

    public enum ServerError: Error, CustomStringConvertible {
        case bindFailed(String)
        public var description: String {
            switch self {
            case .bindFailed(let why): return "socket bind failed: \(why)"
            }
        }
    }

    private let verify: () -> Float?
    private let isScanning: () -> Bool
    private let path: String
    private var listenFD: Int32 = -1
    private var thread: Thread?
    private let onEvent: (String) -> Void

    /// `verify` answers whether the enrolled person is in front of the camera
    /// right now, and may block while it looks. It returns the match distance,
    /// or nil. The PAM module waits a bounded time for the reply, so `verify`
    /// must return well inside that.
    public init(path: String = Paths.socket.path,
                verify: @escaping () -> Float?,
                isScanning: @escaping () -> Bool,
                onEvent: @escaping (String) -> Void) {
        self.verify = verify
        self.isScanning = isScanning
        self.path = path
        self.onEvent = onEvent
    }

    public func start() throws {
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw ServerError.bindFailed(String(cString: strerror(errno)))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw ServerError.bindFailed("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(listenFD)
            throw ServerError.bindFailed(String(cString: strerror(errno)))
        }

        // Only us and root. The containing directory is already 0700, this is
        // the second lock on the same door.
        chmod(path, 0o600)

        guard listen(listenFD, 4) == 0 else {
            close(listenFD)
            throw ServerError.bindFailed(String(cString: strerror(errno)))
        }

        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "io.akshith.macid.socket"
        t.start()
        thread = t
    }

    public func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else {
                if errno == EINTR { continue }
                return
            }
            handle(fd)
            close(fd)
        }
    }

    /// Who is on the other end. A same-uid process could bind this path if the
    /// agent were not running, so the peer check is not a complete defense
    /// against a local attacker already running as this user — but it does stop
    /// any *other* user's process from being answered.
    private func peerUID(_ fd: Int32) -> uid_t? {
        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)
        let ok = withUnsafeMutablePointer(to: &cred) { ptr in
            getsockopt(fd, 0, LOCAL_PEERCRED, ptr, &len)
        }
        guard ok == 0, cred.cr_version == XUCRED_VERSION else { return nil }
        return cred.cr_uid
    }

    private func handle(_ fd: Int32) {
        guard let uid = peerUID(fd) else {
            _ = send(fd, "NO peer-unknown\n")
            return
        }
        guard uid == 0 || uid == getuid() else {
            onEvent("rejected connection from uid \(uid)")
            _ = send(fd, "NO wrong-user\n")
            return
        }

        var buf = [UInt8](repeating: 0, count: 256)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return }
        let request = String(decoding: buf[0..<n], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch request {
        case "VERIFY":
            // Only the PAM module, which runs as root inside loginwindow, may
            // ask. A VERIFY can switch the camera on, and no other process
            // running as this user should be able to do that by connecting.
            guard uid == 0 else {
                onEvent("VERIFY refused from uid \(uid): only the lock screen may ask")
                _ = send(fd, "NO not-root\n")
                return
            }
            if let distance = verify() {
                onEvent(String(format: "VERIFY -> OK (distance %.3f)", distance))
                _ = send(fd, "OK\n")
            } else {
                onEvent("VERIFY -> NO (enrolled face not seen)")
                _ = send(fd, "NO not-seen\n")
            }
        case "STATUS":
            _ = send(fd, isScanning() ? "SCANNING\n" : "IDLE\n")
        default:
            _ = send(fd, "NO bad-request\n")
        }
    }

    @discardableResult
    private func send(_ fd: Int32, _ s: String) -> Int {
        let bytes = Array(s.utf8)
        return bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }
}
