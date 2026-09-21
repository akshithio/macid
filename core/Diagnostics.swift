import Foundation

/// A single JSON readout of every moving part for bug reports, containing no identifying data.
public enum Diagnostics {

    public static func report(includeCamera: Bool = true) -> String {
        var root: [String: Any] = [
            "macid": app(),
            "system": system(),
            "enrollment": enrollment(),
            "config": configuration(),
            "lockScreen": lockScreen(),
            "agent": agent(),
        ]
        root["camera"] = includeCamera ? cameraProbe() : ["authorization": authorization()]

        guard let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            return "{\"error\": \"could not serialize the diagnostics report\"}"
        }
        return text
    }

    private static func app() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "version": info["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": info["CFBundleVersion"] as? String ?? "unknown",
            "bundleID": Bundle.main.bundleIdentifier ?? "none",
        ]
    }

    private static func system() -> [String: Any] {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var machine = [CChar](repeating: 0, count: 64)
        var size = machine.count
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        return [
            "macOS": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            "arch": String(cString: machine),
        ]
    }

    private static func enrollment() -> [String: Any] {
        let faces = Enrollment.faces()
        return [
            "faces": faces.count,
            "samplesPerFace": faces.map(\.samples.count),
            "totalSamples": faces.reduce(0) { $0 + $1.samples.count },
        ]
    }

    private static func configuration() -> [String: Any] {
        let c = Config.load()
        return [
            "sensitivity": c.sensitivity,
            "threshold": Double(c.threshold),
            "requiredFrames": c.requiredFrames,
            "liveness": c.liveness.rawValue,
            "openEyeAspectRatio": c.openEyeAspectRatio,
            "warmWithDisplay": c.warmWithDisplay,
            "scanTimeout": c.scanTimeout,
            "passwordSaved": StoredPassword.isStored,
            "loginKeychainUnlocked": LoginKeychain.isUnlocked,
        ]
    }

    private static func lockScreen() -> [String: Any] {
        var out: [String: Any] = [
            "stack": LockScreen.stack,
            "stackExists": FileManager.default.fileExists(atPath: LockScreen.stack),
        ]
        guard let path = LockScreen.wiredModulePath else {
            out["wired"] = false
            return out
        }
        out["wired"] = true
        out["module"] = path
        out["moduleExists"] = FileManager.default.fileExists(atPath: path)
        out["rootOnlyChain"] = LockScreen.rootOnlyChainProblem(path) == nil
        if let problem = LockScreen.rootOnlyChainProblem(path) {
            out["problem"] = problem
        }
        return out
    }

    private static func agent() -> [String: Any] {
        [
            "socketExists": FileManager.default.fileExists(atPath: Paths.socket.path),
            "supportDirExists": FileManager.default.fileExists(atPath: Paths.dir.path),
        ]
    }

    private static func authorization() -> String {
        do {
            try Camera.ensureAuthorized()
            return "authorized"
        } catch {
            return "denied"
        }
    }

    private static func cameraProbe() -> [String: Any] {
        var out: [String: Any] = ["authorization": authorization()]
        guard out["authorization"] as? String == "authorized" else { return out }

        let camera = Camera()
        do {
            try camera.start { _ in }
        } catch {
            out["error"] = "\(error)"
            return out
        }

        let settled = camera.warmUp()
        Thread.sleep(forTimeInterval: 0.5)
        let delivered = camera.framesDelivered
        let frame = camera.latestFrame
        camera.stop()

        out["framesDelivered"] = delivered
        out["settled"] = settled

        guard let frame else { return out }
        out["brightness"] = Camera.meanLuminance(of: frame)
        out["frameSize"] = "\(frame.width)x\(frame.height)"

        do {
            let detection = try FaceEngine.analyze(frame)
            out["faceDetected"] = true
            out["eyeAspectRatio"] = detection.eyeAspectRatio

            if let descriptor = detection.descriptor,
               let enrolled = try? Enrollment.load(),
               let distance = FaceEngine.distance(from: descriptor, to: enrolled) {
                out["nearestDistance"] = Double(distance)
                out["matched"] = distance <= Config.load().threshold
            }
        } catch {
            out["faceDetected"] = false
            out["detectionError"] = "\(error)"
        }
        return out
    }
}
