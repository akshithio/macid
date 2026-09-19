import Foundation

/// The piece that actually unlocks the Mac: watches the lock, runs the camera,
/// and answers the PAM module over the socket.
///
/// Hosted by MacID.app: it holds the camera grant and starts at login. Only
/// one process may serve the socket at a time; `start()` refuses if another
/// already is, so the app and a leftover launchd agent from an older build
/// never fight over the camera or the socket.
public final class Agent {

    public enum AgentError: Error, CustomStringConvertible {
        case alreadyRunning
        public var description: String {
            "another MacID agent is already running on \(Paths.socket.path)"
        }
    }

    private let state = VerificationState()
    private var server: SocketServer?
    private let camera = Camera()
    private let monitor = LockMonitor()
    private let lock = NSLock()
    /// Held for the duration of a scan so two VERIFYs never open the camera at once.
    private let scanLock = NSLock()
    private var locked = false
    // A stop from off the capture queue; used on unlock. Stopping from inside a
    // frame callback can deadlock AVFoundation, which is why runScan stops on
    // its own (socket) thread instead.
    private let control = DispatchQueue(label: "io.akshith.macid.control")

    /// A VERIFY that starts the camera cold waits for this long for the face to
    /// appear before giving up. It must stay under the PAM module's own reply
    /// timeout, or the lock screen gives up first and falls through to the
    /// password while the camera is still looking.
    private static let verifyTimeout: TimeInterval = 3.5

    public private(set) var isRunning = false

    private let requestsCameraAccess: Bool

    /// `requestsCameraAccess: false` for hosts with their own UI that asks at a
    /// moment the user understands, rather than the instant the process starts.
    public init(requestsCameraAccess: Bool = true) {
        self.requestsCameraAccess = requestsCameraAccess
    }

    public var isScanning: Bool { camera.isRunning }

    public func start() throws {
        guard !isRunning else { return }
        if SocketClient.agentIsRunning { throw AgentError.alreadyRunning }

        Log.line("agent starting (uid \(getuid()), pid \(getpid()))")

        // The socket comes up unconditionally. Enrollment and settings are read
        // fresh on every lock rather than once at startup, so enrolling,
        // re-enrolling, resetting or changing a setting takes effect the next
        // time the screen locks — no restart, and no state where the agent is
        // alive but will never vouch.
        let server = SocketServer(
            verify: { [weak self] in self?.verifyNow() },
            isScanning: { [weak self] in self?.camera.isRunning ?? false },
            onEvent: { Log.line("socket: \($0)") })
        try server.start()
        self.server = server
        Log.line("listening on \(Paths.socket.path)")

        // Camera permission belongs to whichever process macOS holds
        // responsible, and no permission prompt can appear at the lock screen.
        // Ask now, while someone is at the desk to answer.
        if requestsCameraAccess { DispatchQueue.global().async {
            do {
                try Camera.ensureAuthorized()
                Log.line("camera access: granted")
            } catch {
                Log.line("camera access: \(error)")
            }
        } }

        monitor.start(onLock: { [weak self] in self?.onLock() },
                      onUnlock: { [weak self] in self?.onUnlock() })

        // Starting up already at the lock screen is a normal case after a reboot.
        if LockMonitor.isLocked {
            lock.lock(); locked = true; lock.unlock()
        }

        isRunning = true
        Log.line("ready")
    }

    public func stop() {
        guard isRunning else { return }
        monitor.stop()
        onUnlock()
        server?.stop()
        server = nil
        isRunning = false
        Log.line("agent stopped")
    }

    private func onLock() {
        lock.lock(); locked = true; lock.unlock()
        Log.line("screen locked")
    }

    private func onUnlock() {
        lock.lock(); locked = false; lock.unlock()
        state.disarm()
        control.async { [camera] in
            if camera.isRunning { camera.stop() }
        }
        Log.line("screen unlocked")
    }

    /// Answers a VERIFY from the lock screen: is the enrolled person in front of
    /// the camera right now?
    ///
    /// Runs on the socket's accept thread — the root PAM module is blocked
    /// waiting on it — so it is allowed to block, up to `verifyTimeout`. The
    /// camera is switched on only for the moment of an actual unlock attempt,
    /// which is what keeps the indicator light honest: on exactly when someone
    /// is being recognized, off otherwise.
    private func verifyNow() -> Float? {
        // A match from a scan moments ago (a second Return press, or a retry)
        // is redeemed without opening the camera again.
        let (armed, armedDistance) = state.consume()
        if armed { return armedDistance }

        // One scan at a time. A racing VERIFY waits here rather than starting a
        // second capture session on the same camera.
        scanLock.lock()
        defer { scanLock.unlock() }
        let (armed2, d2) = state.consume()
        if armed2 { return d2 }

        let enrolled: [FaceEngine.Descriptor]
        do {
            enrolled = try Enrollment.load()
        } catch {
            Log.line("verify: not enrolled (\(error))")
            return nil
        }

        let config = Config.load()
        let recognizer = Recognizer(config: config, enrolled: enrolled)
        Log.line("verify: looking (\(enrolled.count) samples, threshold \(config.threshold))")

        let distance = runScan(recognizer, timeout: Self.verifyTimeout)
        if let distance {
            state.arm(distance: distance)
            Log.line(String(format: "verify: recognized (distance %.3f)", distance))
        } else {
            Log.line("verify: no match within \(Self.verifyTimeout)s")
        }
        return distance
    }

    /// Start the camera, feed frames to the recognizer until it matches or the
    /// timeout elapses, then stop the camera. Blocks the calling thread.
    ///
    /// Must not be called on the capture delivery queue. It is called on the
    /// socket accept thread, and `camera.stop()` here is the ordinary external
    /// stop — the deadlock the control queue guards against is stopping from
    /// inside a frame callback, which this does not do.
    private func runScan(_ recognizer: Recognizer, timeout: TimeInterval) -> Float? {
        let done = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var result: Float?
        var finished = false

        do {
            try camera.start { image in
                resultLock.lock()
                if finished { resultLock.unlock(); return }
                resultLock.unlock()

                guard case .matched(let distance, _) = recognizer.consider(image) else { return }

                resultLock.lock()
                if !finished {
                    finished = true
                    result = distance
                    done.signal()
                }
                resultLock.unlock()
            }
        } catch {
            Log.line("verify: camera failed (\(error))")
            return nil
        }

        _ = done.wait(timeout: .now() + timeout)
        resultLock.lock()
        finished = true            // stop feeding frames still in flight
        let distance = result
        resultLock.unlock()

        camera.stop()
        return distance
    }
}
