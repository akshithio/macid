import Foundation

/// The piece that actually unlocks the Mac: watches the lock, runs the camera,
/// and answers the PAM module over the socket.
///
/// Hosted by whichever process is running it — the MacID app, or `macid run`
/// under launchd for command-line installs. Only one may serve the socket at a
/// time; `start()` refuses if another already is, so the app and a leftover
/// launchd agent never fight over the camera or the socket.
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
    private var recognizer: Recognizer?
    private var scanDeadline = Date.distantPast
    // stopRunning() must not be called from the capture queue that is
    // delivering the frame — AVFoundation can deadlock waiting on it.
    private let control = DispatchQueue(label: "io.akshith.macid.control")

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
        let server = SocketServer(state: state) { Log.line("socket: \($0)") }
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

        monitor.start(onLock: { [weak self] in self?.beginScanning() },
                      onUnlock: { [weak self] in self?.endScanning() })

        // Starting up already at the lock screen is a normal case after a reboot.
        if LockMonitor.isLocked { beginScanning() }

        isRunning = true
        Log.line("ready")
    }

    public func stop() {
        guard isRunning else { return }
        monitor.stop()
        endScanning()
        server?.stop()
        server = nil
        isRunning = false
        Log.line("agent stopped")
    }

    private func stopCamera(_ why: String) {
        control.async { [camera] in
            guard camera.isRunning else { return }
            camera.stop()
            Log.line(why)
        }
    }

    private func beginScanning() {
        let config = Config.load()
        let enrolled: [FaceEngine.Descriptor]
        do {
            enrolled = try Enrollment.load()
        } catch {
            Log.line("screen locked — not scanning: \(error)")
            return
        }

        lock.lock()
        guard !camera.isRunning else { lock.unlock(); return }
        recognizer = Recognizer(config: config, enrolled: enrolled)
        scanDeadline = Date().addingTimeInterval(config.scanTimeout)
        lock.unlock()

        Log.line("screen locked — camera on (\(enrolled.count) samples, threshold \(config.threshold))")

        do {
            try camera.start { [weak self] image in
                guard let self else { return }
                self.lock.lock()
                let expired = Date() > self.scanDeadline
                let current = self.recognizer
                self.lock.unlock()

                if expired {
                    self.stopCamera("scan window elapsed — camera off")
                    return
                }

                guard let current,
                      case .matched(let distance, let frames) = current.consider(image) else { return }

                self.lock.lock()
                self.recognizer = nil   // ignore frames still in flight
                self.lock.unlock()

                self.state.arm(distance: distance)
                Log.line(String(format: "recognized (distance %.3f, %d frames) — token armed for %ds",
                                distance, frames, Int(VerificationState.lifetime)))
                // Stop the moment there is an answer: the indicator light should
                // be on for exactly as long as it has to be.
                self.stopCamera("camera off")
            }
        } catch {
            Log.line("camera failed: \(error)")
        }
    }

    private func endScanning() {
        lock.lock()
        recognizer = nil
        lock.unlock()
        state.disarm()
        stopCamera("screen unlocked — camera off, token cleared")
    }
}
