import Foundation
import MacIDCore
import CoreGraphics

// MARK: - Logging

enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static var echoToStdout = true

    static func line(_ message: String) {
        let stamp = formatter.string(from: Date())
        let entry = "\(stamp) \(message)\n"
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

    let camera = Camera()
    var descriptors: [FaceEngine.Descriptor] = []
    var attempts = 0

    while descriptors.count < requested && attempts < requested * 4 {
        attempts += 1
        let prompt = prompts[min(descriptors.count, prompts.count - 1)]
        print("  [\(descriptors.count + 1)/\(requested)] \(prompt)... ", terminator: "")
        fflush(stdout)

        Thread.sleep(forTimeInterval: 1.2)

        do {
            let frame = try camera.grabOne()
            let detection = try FaceEngine.analyze(frame)
            guard let descriptor = detection.descriptor else {
                print("no descriptor, retrying")
                continue
            }
            descriptors.append(descriptor)
            print("ok")
        } catch {
            print("\(error) — retrying")
        }
    }

    guard descriptors.count >= 3 else {
        fail("only captured \(descriptors.count) samples, need at least 3. Better lighting usually fixes this.")
    }

    // Calibration. The spread among your own samples is the only honest basis
    // for a threshold: if your own face varies by up to N, the cutoff has to sit
    // above N or you will never match, and well below the distance to a
    // stranger or anyone matches.
    var spreads: [Float] = []
    for i in 0..<descriptors.count {
        for j in (i + 1)..<descriptors.count {
            if let d = FaceEngine.distance(from: descriptors[i], to: [descriptors[j]]) {
                spreads.append(d)
            }
        }
    }

    var config = Config.load()
    if let worst = spreads.max(), !spreads.isEmpty {
        let mean = spreads.reduce(0, +) / Float(spreads.count)
        // Sit above the worst self-match with headroom, but never so loose that
        // the gate stops meaning anything.
        let suggested = min(max(worst * 1.25, 0.30), 0.75)
        config.threshold = suggested
        print(String(format: """

            Calibration
              self-match distance   mean %.3f, worst %.3f
              threshold set to      %.3f
            """, mean, worst, suggested))
        if worst > 0.5 {
            print("  note: your samples vary a lot. Re-enroll in even lighting for a tighter threshold.")
        }
    }

    do {
        try Enrollment.save(descriptors)
        try config.save()
    } catch {
        fail("could not save enrollment: \(error)")
    }

    print("""

        Enrolled \(descriptors.count) samples -> \(Paths.enrolled.path)

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
    Log.line("macid starting (uid \(getuid()))")

    let config = Config.load()
    guard Enrollment.isEnrolled else {
        Log.line("no enrolled face — idling. Run 'macid enroll' and restart the agent.")
        // Stay alive rather than crash-looping under launchd.
        RunLoop.current.run()
        return
    }

    let enrolled: [FaceEngine.Descriptor]
    do {
        enrolled = try Enrollment.load()
    } catch {
        fail("\(error)")
    }

    let state = VerificationState()
    let server = SocketServer(state: state) { Log.line("socket: \($0)") }
    do {
        try server.start()
        Log.line("listening on \(Paths.socket.path)")
    } catch {
        fail("\(error)")
    }

    let camera = Camera()
    let monitor = LockMonitor()
    var recognizer = Recognizer(config: config, enrolled: enrolled)
    var scanDeadline = Date.distantPast
    let lock = NSLock()

    func beginScanning() {
        lock.lock(); defer { lock.unlock() }
        guard !camera.isRunning else { return }

        recognizer = Recognizer(config: config, enrolled: enrolled)
        scanDeadline = Date().addingTimeInterval(config.scanTimeout)
        Log.line("screen locked — camera on")

        do {
            try camera.start { image in
                lock.lock()
                let expired = Date() > scanDeadline
                lock.unlock()

                if expired {
                    Log.line("scan window elapsed — camera off")
                    camera.stop()
                    return
                }

                switch recognizer.consider(image) {
                case .matched(let distance, let frames):
                    Log.line(String(format: "recognized (distance %.3f, %d frames) — token armed for %ds",
                                    distance, frames, Int(VerificationState.lifetime)))
                    state.arm(distance: distance)
                    // Stop the camera the moment we have an answer. Holding it
                    // open would keep the indicator light on and buy nothing.
                    camera.stop()
                case .searching, .rejected:
                    break
                }
            }
        } catch {
            Log.line("camera failed: \(error)")
        }
    }

    func endScanning() {
        Log.line("screen unlocked — camera off, token cleared")
        camera.stop()
        state.disarm()
    }

    monitor.start(onLock: beginScanning, onUnlock: endScanning)

    // Starting up already at the lock screen is a normal case after a reboot.
    if LockMonitor.isLocked { beginScanning() }

    Log.line("ready")
    RunLoop.current.run()
}

// MARK: - status

func status() {
    let config = Config.load()
    print("""
    enrollment   \(Enrollment.isEnrolled ? "yes (\((try? Enrollment.load())?.count ?? 0) samples)" : "NO — run: macid enroll")
    threshold    \(config.threshold)
    frames       \(config.requiredFrames)
    blink        \(config.requireBlink ? "required" : "NOT REQUIRED (photo-spoofable)")
    socket       \(FileManager.default.fileExists(atPath: Paths.socket.path) ? "present" : "absent — agent not running")
    screen       \(LockMonitor.isLocked ? "locked" : "unlocked")
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
      macid install      wire the lock screen + load the agent (needs sudo)
      macid uninstall    remove everything (needs sudo)
      macid reset        delete enrolled face data
    """)
}
