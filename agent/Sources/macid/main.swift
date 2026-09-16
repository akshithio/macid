import Foundation
import MacIDCore
import CoreGraphics

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("macid: \(message)\n".utf8))
    exit(1)
}

// MARK: - enroll

func enroll(samples requested: Int) {
    do {
        try Camera.ensureAuthorized()
    } catch {
        fail("\(error)")
    }

    let prompts = [
        "look straight at the camera",
        "hold still",
        "tilt your head slightly left",
        "tilt your head slightly right",
        "chin up a little",
        "chin down a little",
        "look straight again",
        "last one",
    ]

    print("Enrolling. \(requested) samples — this takes about 20 seconds.\n")

    // One session for the whole run. Starting and stopping the camera per
    // sample means every sample is a first frame, and first frames are black.
    let camera = Camera()
    do {
        try camera.start { _ in }
    } catch {
        fail("\(error)")
    }
    defer { camera.stop() }

    print("  warming up the camera...")
    guard camera.warmUp() else {
        fail("camera delivered no frames. Run `macid doctor` for details.")
    }

    var samples: [Calibration.Sample] = []
    var attempts = 0
    var darkFrames = 0

    while samples.count < requested && attempts < requested * 4 {
        attempts += 1
        let prompt = prompts[min(samples.count, prompts.count - 1)]
        print("  [\(samples.count + 1)/\(requested)] \(prompt)... ", terminator: "")
        fflush(stdout)

        Thread.sleep(forTimeInterval: 1.0)

        guard let frame = camera.latestFrame else {
            print("no frame, retrying")
            continue
        }

        do {
            samples.append(try Calibration.Sample(FaceEngine.analyze(frame)))
            print("ok")
        } catch {
            // A black frame and an empty room look the same to a face detector,
            // so say which one this is rather than repeating "no face".
            let luma = Camera.meanLuminance(of: frame)
            if luma >= 0 && luma < 0.02 {
                darkFrames += 1
                print("frame is black (luminance \(String(format: "%.3f", luma))) — retrying")
            } else {
                print("\(error) — retrying")
            }
        }
    }

    if darkFrames > 0 && samples.count < Calibration.minimumSamples {
        fail("""
        the camera is producing black frames.
          - is the lid closed, or something covering the camera?
          - is another app holding the camera? quit it and retry
          - run `macid doctor` for a full readout
        """)
    }

    let result: Calibration.Result
    do {
        result = try Calibration.commit(samples)
    } catch {
        fail("\(error)")
    }

    print(String(format: """

        Calibration
          self-match distance   mean %.3f, worst %.3f
          threshold set to      %.3f
          open-eye baseline     %.3f
        """, result.meanSpread, result.worstSpread, result.threshold, result.openEyeAspectRatio))
    if result.isNoisy {
        print("  note: your samples vary a lot. Re-enroll in even lighting for a tighter threshold.")
    }

    print("""

        Enrolled \(result.samples) samples -> \(Paths.enrolled.path)

        Check it works before trusting it:  macid test
        """)
}

// MARK: - test

func runTest() {
    let config = Config.load()
    let enrolled: [FaceEngine.Descriptor]
    do {
        enrolled = try Enrollment.load()
    } catch {
        fail("\(error)")
    }

    print("Testing recognition — look at the camera and blink. Ctrl-C to stop.\n")

    let recognizer = Recognizer(config: config, enrolled: enrolled)
    let camera = Camera()
    let deadline = Date().addingTimeInterval(30)
    var finished = false
    let lock = NSLock()

    do {
        try camera.start { image in
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }

            switch recognizer.consider(image) {
            case .searching(let why):
                print("  \(why)\u{1B}[K\r", terminator: "")
                fflush(stdout)
            case .matched(let distance, let frames):
                finished = true
                print(String(format: "\n\n  MATCH — distance %.3f after %d frames, blink confirmed.\n",
                             distance, frames))
            case .rejected(let why):
                finished = true
                print("\n\n  REJECTED: \(why)\n")
            }
        }
    } catch {
        fail("\(error)")
    }

    while !finished && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    camera.stop()

    if !finished {
        print("\n\n  No match in 30s. If it kept saying 'distance X > Y', re-run: macid enroll\n")
        exit(1)
    }
}

// MARK: - run (the agent)

func runAgent() {
    Log.echoToStdout = true
    let agent = Agent()
    do {
        try agent.start()
    } catch Agent.AgentError.alreadyRunning {
        // The MacID app is hosting the agent. Exit cleanly: under launchd with
        // KeepAlive, a crash here would just be restarted into the same state.
        Log.line("macid run: the MacID app is already running the agent — exiting")
        exit(0)
    } catch {
        fail("\(error)")
    }
    RunLoop.current.run()
}


// MARK: - doctor

/// One readout of every moving part, for when something does not work.
func doctor() {
    print("MacID doctor\n")

    let authorized: Bool
    do {
        try Camera.ensureAuthorized()
        authorized = true
    } catch {
        authorized = false
    }
    print("camera access   \(authorized ? "granted" : "DENIED — System Settings > Privacy & Security > Camera")")

    guard authorized else { return }

    let camera = Camera()
    do {
        try camera.start { _ in }
    } catch {
        print("camera start    FAILED: \(error)")
        return
    }

    let settled = camera.warmUp()
    Thread.sleep(forTimeInterval: 0.5)
    let frames = camera.framesDelivered
    let frame = camera.latestFrame
    camera.stop()

    print("frames          \(frames) delivered\(settled ? "" : " (never settled)")")

    guard let frame else {
        print("\nNo frames at all. Something else is probably holding the camera.")
        return
    }

    let luma = Camera.meanLuminance(of: frame)
    print("frame size      \(frame.width)x\(frame.height)")
    print(String(format: "brightness      %.3f%@", luma,
                 luma < 0.02 ? "  <- black; lid closed, covered, or in use elsewhere" : ""))

    do {
        let detection = try FaceEngine.analyze(frame)
        print(String(format: "face            detected (eye aspect ratio %.3f)",
                     detection.eyeAspectRatio))
        if let descriptor = detection.descriptor,
           let enrolled = try? Enrollment.load(),
           let distance = FaceEngine.distance(from: descriptor, to: enrolled) {
            let threshold = Config.load().threshold
            print(String(format: "match           distance %.3f vs threshold %.3f -> %@",
                         distance, threshold, distance <= threshold ? "MATCH" : "no match"))
        }
    } catch {
        print("face            \(error)")
    }

    print("")
    status()
}

// MARK: - status

/// Where the lock screen module is loaded from, and whether that location is
/// one only root can change.
func moduleStatus() -> String {
    guard let path = LockScreen.wiredModulePath else { return "not wired into \(LockScreen.stack)" }
    if let problem = LockScreen.rootOnlyChainProblem(path) {
        return "\(path) — UNSAFE: \(problem). Reinstall: sudo make install"
    }
    return "\(path) (root-only path)"
}


func status() {
    let config = Config.load()
    print("""
    enrollment   \(Enrollment.isEnrolled ? "yes (\((try? Enrollment.load())?.count ?? 0) samples)" : "NO — run: macid enroll")
    threshold    \(config.threshold)
    frames       \(config.requiredFrames)
    liveness     \(config.liveness == .blink ? "attention + blink" : "attention (eyes open; a photo can pass)")
    socket       \(FileManager.default.fileExists(atPath: Paths.socket.path) ? "present" : "absent — agent not running")
    screen       \(LockMonitor.isLocked ? "locked" : "unlocked")
    module       \(moduleStatus())
    data         \(Paths.dir.path)
    """)
}

// MARK: - dispatch

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "enroll":
    let n = args.count > 1 ? Int(args[1]) ?? 8 : 8
    enroll(samples: n)
case "run":
    runAgent()
case "test":
    runTest()
case "status":
    status()
case "doctor":
    doctor()
case "install":
    Install.install()
case "uninstall":
    Install.uninstall()
case "reset":
    try? Enrollment.clear()
    print("enrollment cleared")
default:
    print("""
    MacID — face unlock for the macOS lock screen

      macid enroll [n]   capture n samples of your face (default 8)
      macid test         verify recognition works, right now
      macid run          run the agent (launchd does this for you)
      macid status       show current state
      macid doctor       diagnose camera and recognition problems
      macid install      wire the lock screen + load the agent (needs sudo)
      macid uninstall    remove everything (needs sudo)
      macid reset        delete enrolled face data
    """)
}
