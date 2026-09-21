import Foundation

/// One readout of every moving part, for when face unlock silently stops
/// working.
///
/// This used to be `macid status` and `macid doctor`. The lock screen PAM stack
/// is not API — it moved between macOS releases before and it will again — and
/// when it moves, the failure is silent: you press Return and nothing happens.
/// The questions you need answered then are always the same, so they are
/// answered here as data rather than printed text, and the app renders them.
public enum Diagnostics {

    public enum Health: Sendable {
        /// Working as intended.
        case ok
        /// Works, but not the way you probably want.
        case warning
        /// This is why face unlock is not working.
        case bad
    }

    public struct Check: Identifiable, Sendable {
        public let id = UUID()
        public let name: String
        public let value: String
        public let health: Health
        /// What to do about it, when there is something to do.
        public let remedy: String?

        public init(_ name: String, _ value: String, _ health: Health = .ok, remedy: String? = nil) {
            self.name = name
            self.value = value
            self.health = health
            self.remedy = remedy
        }
    }

    // MARK: - Configuration and wiring

    /// The cheap checks: no camera, no waiting. Safe to run on a timer.
    public static func state() -> [Check] {
        let config = Config.load()
        var checks: [Check] = []

        let samples = (try? Enrollment.load().count) ?? 0
        checks.append(Check(
            "Enrolled face",
            samples > 0 ? "\(samples) samples" : "none",
            samples > 0 ? .ok : .bad,
            remedy: samples > 0 ? nil : "Enroll your face in MacID."))

        // A threshold is a distance, so bigger is looser. Calibration derives
        // it from the noise floor measured during enrollment and never returns
        // more than 0.55; anything above that was written by an older build
        // whose threshold came from pose variety rather than noise.
        let loose = config.threshold > 0.55
        checks.append(Check(
            "Match threshold",
            String(format: "%.3f", config.threshold),
            loose ? .warning : .ok,
            remedy: loose
                ? "Looser than this build would ever calibrate. Re-enroll to recalculate it."
                : nil))

        checks.append(Check("Frames to agree", "\(config.requiredFrames)"))

        checks.append(Check(
            "Liveness",
            config.liveness == .blink ? "attention + blink" : "attention only",
            config.liveness == .blink ? .ok : .warning,
            remedy: config.liveness == .blink ? nil : "Eyes open is all that is required, so a photo can pass."))

        checks.append(Check(
            "Agent socket",
            FileManager.default.fileExists(atPath: Paths.socket.path) ? "listening" : "absent",
            FileManager.default.fileExists(atPath: Paths.socket.path) ? .ok : .bad,
            remedy: FileManager.default.fileExists(atPath: Paths.socket.path)
                ? nil
                : "MacID is not serving the socket. Quit and reopen the app."))

        checks.append(lockScreenCheck())
        return checks
    }

    /// Where the lock screen loads the module from, and whether that path is
    /// one only root can change. A module in a user-writable directory is a
    /// module anyone on the machine can replace.
    private static func lockScreenCheck() -> Check {
        guard let path = LockScreen.wiredModulePath else {
            return Check("Lock screen", "not wired into \(LockScreen.stack)", .bad,
                         remedy: "Turn on face unlock in MacID.")
        }
        if let problem = LockScreen.rootOnlyChainProblem(path) {
            return Check("Lock screen", "UNSAFE — \(problem)", .bad,
                         remedy: "Turn face unlock off and on again to reinstall the module.")
        }
        return Check("Lock screen", "\(path)", .ok)
    }

    // MARK: - Camera

    /// The expensive checks: opens the camera, waits for it to settle, and
    /// tries to recognize whoever is in front of it. Run on demand, never on a
    /// timer — it competes with the agent for the camera.
    ///
    /// Not `async` on purpose: it blocks on frame delivery. Call it off the
    /// main actor.
    public static func cameraReport() -> [Check] {
        do {
            try Camera.ensureAuthorized()
        } catch {
            return [Check("Camera access", "denied", .bad,
                          remedy: "System Settings > Privacy & Security > Camera, and allow MacID.")]
        }

        var checks = [Check("Camera access", "granted")]

        let camera = Camera()
        do {
            try camera.start { _ in }
        } catch {
            checks.append(Check("Camera", "failed to start: \(error)", .bad,
                                remedy: "Another app may be holding the camera. Quit it and try again."))
            return checks
        }

        let settled = camera.warmUp()
        Thread.sleep(forTimeInterval: 0.5)
        let delivered = camera.framesDelivered
        let frame = camera.latestFrame
        camera.stop()

        checks.append(Check(
            "Frames",
            "\(delivered) delivered\(settled ? "" : " (never settled)")",
            delivered > 0 ? (settled ? .ok : .warning) : .bad,
            remedy: delivered > 0 ? nil : "Something else is probably holding the camera."))

        guard let frame else { return checks }

        // A black frame and an empty room look identical to a face detector,
        // so name which one this is rather than reporting "no face".
        let luma = Camera.meanLuminance(of: frame)
        checks.append(Check("Frame size", "\(frame.width)x\(frame.height)"))
        checks.append(Check(
            "Brightness",
            String(format: "%.3f", luma),
            luma < 0.02 ? .bad : .ok,
            remedy: luma < 0.02 ? "The frame is black: lid closed, camera covered, or in use elsewhere." : nil))

        do {
            let detection = try FaceEngine.analyze(frame)
            checks.append(Check("Face", String(format: "detected (eye aspect ratio %.3f)",
                                               detection.eyeAspectRatio)))

            if let descriptor = detection.descriptor,
               let enrolled = try? Enrollment.load(),
               let distance = FaceEngine.distance(from: descriptor, to: enrolled) {
                let threshold = Config.load().threshold
                let matched = distance <= threshold
                checks.append(Check(
                    "Match",
                    String(format: "distance %.3f vs threshold %.3f — %@",
                           distance, threshold, matched ? "match" : "no match"),
                    matched ? .ok : .warning,
                    remedy: matched ? nil : "Re-enroll if this keeps happening in good light."))
            }
        } catch {
            checks.append(Check("Face", "\(error)", .warning))
        }

        return checks
    }
}
