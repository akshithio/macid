import Foundation
import CoreGraphics

/// Watches the lock, runs the camera, and answers the PAM module over the socket.
/// Only one process may serve the socket; `start()` refuses if another already is.
public final class Agent {

    public enum AgentError: Error, CustomStringConvertible {
        case alreadyRunning
        public var description: String {
            "another MacID agent is already running on \(Paths.socket.path)"
        }
    }

    private var server: SocketServer?
    private let camera = Camera()
    private let monitor = LockMonitor()
    private let lock = NSLock()
    private let scanLock = NSLock()
    private var locked = false
    private let control = DispatchQueue(label: "io.akshith.macid.control")

    private static let verifyTimeout: TimeInterval = 3.5

    private static let nonMatchesToConclude = 8

    private static let farNonMatchesToConclude = 3

    private var frameSink: ((CGImage) -> Void)?
    private let sinkLock = NSLock()
    private var pendingPassword: String?
    private let freshness = PasswordFreshness()
    private var displayTimer: DispatchSourceTimer?
    private var warmWithDisplay = true

    public private(set) var isRunning = false

    private let requestsCameraAccess: Bool

    public init(requestsCameraAccess: Bool = true) {
        self.requestsCameraAccess = requestsCameraAccess
    }

    public var isScanning: Bool { camera.isRunning }

    public func start() throws {
        guard !isRunning else { return }
        if SocketClient.agentIsRunning { throw AgentError.alreadyRunning }

        Log.line("agent starting (uid \(getuid()), pid \(getpid()))")

        let server = SocketServer(
            verify: { [weak self] in self?.verifyNow() },
            isScanning: { [weak self] in self?.isRecognizing ?? false },
            onEvent: { Log.line("socket: \($0)") })
        try server.start()
        self.server = server
        Log.line("listening on \(Paths.socket.path)")

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
        warmWithDisplay = Config.load().warmWithDisplay
        guard warmWithDisplay else {
            Log.line("screen locked — camera starts on Return")
            return
        }
        startDisplayWatch()
        control.async { [weak self] in self?.pollDisplay() }
        Log.line("screen locked")
    }

    private func onUnlock() {
        lock.lock(); locked = false; lock.unlock()
        stopDisplayWatch()
        setSink(nil as ((CGImage) -> Void)?)
        let notified = Date()
        control.async { [camera] in
            guard camera.isRunning else { return }
            camera.stop()
            Log.line(String(format: "camera off %.0fms after unlock", Date().timeIntervalSince(notified) * 1000))
        }
        Log.line("screen unlocked")

        sinkLock.lock(); let password = pendingPassword; pendingPassword = nil; sinkLock.unlock()
        if password == nil { freshness.credentialPresented() }
        if let password { unlockKeychain(with: password) }
    }

    private func unlockKeychain(with password: String) {
        let attempt: (String) -> Void = { when in
            if StoredPassword.unlockKeychain(with: password) {
                Log.line("login keychain unlocked (\(when))")
            } else {
                StoredPassword.clear()
                Log.line("login keychain refused the saved password; removed it (\(when))")
            }
        }
        control.async { attempt("at unlock") }
        control.asyncAfter(deadline: .now() + 1.5) { attempt("recheck") }
    }

    private var isRecognizing: Bool {
        sinkLock.lock(); defer { sinkLock.unlock() }
        return frameSink != nil
    }

    private func setSink(_ sink: ((CGImage) -> Void)?) {
        sinkLock.lock(); frameSink = sink; sinkLock.unlock()
    }

    private func ensureSession() -> Bool {
        if camera.isRunning { return true }
        do {
            try camera.start { [weak self] image in
                guard let self else { return }
                self.sinkLock.lock()
                let sink = self.frameSink
                self.sinkLock.unlock()
                sink?(image)
            }
            return true
        } catch {
            Log.line("camera failed (\(error))")
            return false
        }
    }

    private func startDisplayWatch() {
        guard displayTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 0.4, repeating: 0.4)
        timer.setEventHandler { [weak self] in self?.pollDisplay() }
        timer.resume()
        displayTimer = timer
    }

    private func stopDisplayWatch() {
        displayTimer?.cancel()
        displayTimer = nil
    }

    private func pollDisplay() {
        lock.lock(); let isLocked = locked; lock.unlock()

        guard scanLock.try() else { return }
        defer { scanLock.unlock() }

        let shouldBeWarm = isLocked && warmWithDisplay
            && CGDisplayIsAsleep(CGMainDisplayID()) == 0
            && StoredPassword.isStored
            && freshness.reasonPasswordRequired == nil
            && !TouchIDState.requiresPassword

        if shouldBeWarm && !camera.isRunning {
            if ensureSession() { Log.line("lock screen showing — camera warming") }
        } else if !shouldBeWarm && camera.isRunning && !isRecognizing {
            camera.stop()
            Log.line("camera cold again")
        }
    }

    private func verifyNow() -> SocketServer.Match? {
        if let reason = freshness.reasonPasswordRequired {
            Log.line("verify: password needed, \(reason)")
            return nil
        }
        guard !TouchIDState.requiresPassword else {
            Log.line("verify: Touch ID wants the password, so does MacID")
            return nil
        }

        guard let password = StoredPassword.load() else {
            Log.line("verify: no saved password, password needed")
            return nil
        }
        guard StoredPassword.isCorrect(password) else {
            StoredPassword.clear()
            Log.line("verify: saved password is out of date, removed it")
            return nil
        }

        guard let distance = recognize() else { return nil }
        sinkLock.lock(); pendingPassword = password; sinkLock.unlock()
        return SocketServer.Match(distance: distance, password: password)
    }

    private func recognize() -> Float? {
        scanLock.lock()
        defer { scanLock.unlock() }

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
            Log.line(String(format: "verify: recognized (distance %.3f)", distance))
        } else {
            Log.line("verify: no match")
        }
        return distance
    }

    private func runScan(_ recognizer: Recognizer, timeout: TimeInterval) -> Float? {
        let done = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var result: Float?
        var finished = false

        let wasWarm = camera.isRunning
        guard ensureSession() else { return nil }

        setSink { image in
            resultLock.lock()
            if finished { resultLock.unlock(); return }
            resultLock.unlock()

            guard case .matched(let distance, _) = recognizer.consider(image) else {
                let concluded = recognizer.consecutiveNonMatches >= Self.nonMatchesToConclude
                    || recognizer.consecutiveFarNonMatches >= Self.farNonMatchesToConclude
                guard concluded else { return }
                resultLock.lock()
                if !finished {
                    finished = true
                    done.signal()
                }
                resultLock.unlock()
                return
            }

            resultLock.lock()
            if !finished {
                finished = true
                result = distance
                done.signal()
            }
            resultLock.unlock()
        }

        _ = done.wait(timeout: .now() + timeout)
        resultLock.lock()
        finished = true
        let distance = result
        resultLock.unlock()

        setSink(nil)

        if !wasWarm { camera.stop() }
        return distance
    }

}
