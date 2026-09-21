import SwiftUI
import MacIDCore

/// Live camera feed shared by enrollment and testing.
@MainActor
final class CameraFeed: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published private(set) var faceVisible = false
    @Published private(set) var error: String?

    let camera = Camera()
    private let counter = FrameCounter()

    func start() {
        guard !camera.isRunning else { return }
        do {
            try camera.start { [weak self] frame in
                guard let self else { return }
                let count = self.counter.next()
                let seen: Bool? = count % 6 == 0
                    ? (try? FaceEngine.analyze(frame, wantDescriptor: false)) != nil
                    : nil
                guard count % 2 == 0 || seen != nil else { return }
                Task { @MainActor in
                    self.image = frame
                    if let seen { self.faceVisible = seen }
                }
            }
        } catch {
            self.error = "\(error)"
        }
    }

    func stop() {
        camera.stop()
        image = nil
        faceVisible = false
    }

}

/// Counts frames on the camera's delivery queue, off the main actor.
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

struct CameraPreview: View {
    @ObservedObject var feed: CameraFeed
    var highlight: Color? = nil

    var body: some View {
        ZStack {
            if let image = feed.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(x: -1, y: 1)
            } else {
                Rectangle().fill(.black.opacity(0.85))
                if let error = feed.error {
                    Label(error, systemImage: "video.slash")
                        .foregroundStyle(.white)
                        .font(.callout)
                        .padding()
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
        }
        .frame(width: 400, height: 225)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(highlight ?? (feed.faceVisible ? Color.green : Color.secondary.opacity(0.3)),
                              lineWidth: 2)
        )
        .animation(.easeOut(duration: 0.2), value: feed.faceVisible)
    }
}

@MainActor
final class EnrollModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case capturing
        case done(Calibration.Result)
        case failed(String)

        static func == (a: Phase, b: Phase) -> Bool {
            switch (a, b) {
            case (.ready, .ready), (.capturing, .capturing): return true
            case let (.done(x), .done(y)): return x.samples == y.samples && x.threshold == y.threshold
            case let (.failed(x), .failed(y)): return x == y
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .ready

    @Published private(set) var stepIndex = 0
    @Published private(set) var prompt = ""
    @Published private(set) var guidance = ""
    @Published private(set) var inPosition = false
    /// Overall progress across the run, 0...1.
    @Published private(set) var progress: Double = 0
    @Published private(set) var pose: FaceEngine.Pose?

    let feed = CameraFeed()

    var stepCount: Int { EnrollmentPlan.steps.count }

    /// Samples taken per step.
    private let perStep = 2
    /// How long the head must hold a position before a sample is taken.
    private let holdDuration: Duration = .milliseconds(500)
    private let stepTimeout: Duration = .seconds(25)

    private var task: Task<Void, Never>?

    var isCapturing: Bool { phase == .capturing }

    func begin(name: String = "Me") {
        guard !isCapturing else { return }
        phase = .capturing
        task?.cancel()
        task = Task { await run(name: name) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .ready
        reset()
    }

    private func reset() {
        stepIndex = 0
        prompt = ""
        guidance = ""
        inPosition = false
        progress = 0
        pose = nil
    }

    private func run(name: String) async {
        _ = await Task.detached { [camera = feed.camera] in camera.warmUp() }.value

        var poses: [[Calibration.Sample]] = []
        var signs: [String: Double] = [:]
        let total = EnrollmentPlan.steps.count * perStep
        var takenSoFar = 0
        var baseline: FaceEngine.Pose?

        for (index, step) in EnrollmentPlan.steps.enumerated() {
            if Task.isCancelled { return }

            stepIndex = index
            prompt = step.prompt
            guidance = step.hint
            inPosition = false

            var group: [Calibration.Sample] = []
            await capture(step, signs: &signs, group: &group,
                          takenSoFar: &takenSoFar, total: total, baseline: &baseline)

            if !group.isEmpty { poses.append(group) }
            if Task.isCancelled { return }
            NSSound(named: "Glass")?.play()
        }

        inPosition = false
        prompt = ""
        guidance = ""

        guard !Task.isCancelled else { return }

        do {
            phase = .done(try Calibration.commit(poses: poses, name: name))
        } catch {
            phase = .failed("\(error)")
        }
    }

    /// Waits for the head to hold this step's position, then takes `perStep` samples.
    /// Returns false on timeout.
    @discardableResult
    private func capture(_ step: EnrollmentPlan.Step,
                         signs: inout [String: Double],
                         group: inout [Calibration.Sample],
                         takenSoFar: inout Int,
                         total: Int,
                         baseline: inout FaceEngine.Pose?) async -> Bool {
        let axis = EnrollmentPlan.axis(of: step.target)
        let previousSign = axis.map { signs[key($0)] ?? nil } ?? nil

        var taken = 0
        var heldSince: ContinuousClock.Instant?
        let deadline = ContinuousClock.now + stepTimeout
        var unmeasurable = 0
        var recent: [FaceEngine.Pose] = []
        var strikes = 0
        let strikesAllowed = 3

        while taken < perStep && ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(120))

            guard let frame = feed.camera.latestFrame else { continue }
            let detection = await Task.detached {
                try? FaceEngine.analyze(frame)
            }.value

            guard let detection else {
                strikes += 1
                if strikes > strikesAllowed {
                    pose = nil
                    inPosition = false
                    heldSince = nil
                    recent.removeAll()
                    guidance = "Can't see your face"
                }
                continue
            }

            recent.append(detection.pose)
            if recent.count > 5 { recent.removeFirst() }
            let smoothed = EnrollmentPlan.smoothed(recent)
            pose = smoothed
            let verdict = EnrollmentPlan.judge(smoothed,
                                               against: step.target,
                                               previousSign: previousSign,
                                               holding: heldSince != nil,
                                               baseline: baseline)

            if verdict == .unmeasurable {
                unmeasurable += 1
                if unmeasurable > 12 {
                    guidance = "Hold still"
                    inPosition = true
                    let now = ContinuousClock.now
                    guard let since = heldSince else { heldSince = now; continue }
                    guard now - since >= holdDuration else { continue }
                    if let sample = try? Calibration.Sample(detection) {
                        group.append(sample)
                        taken += 1
                        takenSoFar += 1
                        progress = Double(takenSoFar) / Double(total)
                        heldSince = nil
                    }
                    continue
                }
            }

            guidance = message(for: verdict, step: step)
            inPosition = verdict == .good

            guard verdict == .good else {
                strikes += 1
                if strikes > strikesAllowed {
                    heldSince = nil
                    inPosition = false
                }
                continue
            }
            strikes = 0

            if let axis, case .away = step.target,
               let angle = EnrollmentPlan.offset(of: axis, in: smoothed, from: baseline) {
                signs[key(axis)] = angle
            }
            if case .centered = step.target, baseline == nil {
                baseline = smoothed
            }

            let now = ContinuousClock.now
            guard let since = heldSince else { heldSince = now; continue }
            guard now - since >= holdDuration else { continue }

            if let sample = try? Calibration.Sample(detection) {
                group.append(sample)
                taken += 1
                takenSoFar += 1
                progress = Double(takenSoFar) / Double(total)
                heldSince = nil
            }
        }

        return taken > 0
    }

    private func key(_ axis: EnrollmentPlan.Axis) -> String {
        switch axis {
        case .yaw: return "yaw"
        case .pitch: return "pitch"
        }
    }

    private func message(for verdict: EnrollmentPlan.Verdict,
                         step: EnrollmentPlan.Step) -> String {
        switch verdict {
        case .good: return "Hold it\u{2026}"
        case .notFarEnough: return step.hint
        case .wrongDirection: return "Other way"
        case .unmeasurable: return step.hint
        }
    }
}

struct EnrollPanel: View {
    @StateObject private var model = EnrollModel()
    var name: String = "Me"
    /// Pins the button to the bottom, where setup keeps every step's button.
    var pinsButton = false
    var onFinished: () -> Void = {}

    var body: some View {
        VStack(spacing: 18) {
            CameraPreview(feed: model.feed, highlight: highlight)

            status.frame(minHeight: 86)

            if pinsButton { Spacer(minLength: 0) }

            buttons.frame(height: pinsButton ? OnboardingLayout.buttonHeight : nil)
        }
        .onAppear { model.feed.start() }
        .onDisappear { model.feed.stop(); model.cancel() }
    }

    @ViewBuilder
    private var buttons: some View {
        switch model.phase {
        case .ready:
            Button("Start") { model.begin(name: name) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.feed.faceVisible)
        case .capturing:
            Button("Cancel") { model.cancel() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        case .done:
            Button("Continue") { onFinished() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        case .failed:
            Button("Try Again") { model.begin(name: name) }
                .controlSize(.large)
        }
    }

    private var highlight: Color? {
        switch model.phase {
        case .done: return .green
        case .capturing: return model.inPosition ? .green : .accentColor
        default: return nil
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .ready:
            Text(model.feed.faceVisible
                 ? "Your face is in view. Keep a natural expression."
                 : "Position your face in the frame.")
                .foregroundStyle(.secondary)

        case .capturing:
            VStack(spacing: 8) {
                Text("Step \(model.stepIndex + 1) of \(model.stepCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(model.prompt)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Label(model.guidance,
                      systemImage: model.inPosition ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                    .font(.callout)
                    .foregroundStyle(model.inPosition ? .green : .secondary)
                    .animation(.easeOut(duration: 0.15), value: model.inPosition)

                ProgressView(value: model.progress)
                    .frame(width: 220)
            }

        case .done:
            Label("Face enrolled", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        }
    }
}

@MainActor
final class TestModel: ObservableObject {
    enum Phase: Equatable {
        case looking
        case matched
        case timedOut
    }

    @Published private(set) var phase: Phase = .looking
    @Published private(set) var detail = ""
    let feed = CameraFeed()
    private var task: Task<Void, Never>?

    func run() {
        task?.cancel()
        phase = .looking
        detail = "Look at the camera"
        guard let enrolled = try? Enrollment.load() else {
            phase = .timedOut
            detail = "No face enrolled"
            return
        }
        let recognizer = Recognizer(config: Config.load(), enrolled: enrolled)

        task = Task {
            let deadline = Date().addingTimeInterval(20)
            var lastFrame: CGImage?
            var consecutiveRejections = 0
            let rejectionsToConclude = 10

            while !Task.isCancelled && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(60))
                guard let frame = feed.camera.latestFrame, frame !== lastFrame else { continue }
                lastFrame = frame
                let outcome = await Task.detached { recognizer.consider(frame) }.value
                switch outcome {
                case .matched:
                    phase = .matched
                    detail = "That's you"
                    return
                case .searching(let why):
                    detail = Self.humane(why)
                    if why.contains("face seen, distance") {
                        consecutiveRejections += 1
                        if consecutiveRejections >= rejectionsToConclude { break }
                    } else {
                        consecutiveRejections = 0
                    }
                case .rejected(let why):
                    detail = why
                }
                if consecutiveRejections >= rejectionsToConclude { break }
            }
            if !Task.isCancelled { phase = .timedOut }
        }
    }

    func stop() {
        task?.cancel()
        feed.stop()
    }

    /// Rewrites the recognizer's log-style status strings for display.
    private static func humane(_ why: String) -> String {
        if why.contains("no face") { return "Look at the camera" }
        if why.contains("faces in frame") { return "Only one person should be in view" }
        if why.contains("eyes closed") { return "Keep your eyes open and on the screen" }
        if why.contains("blink") { return "Recognized \u{2014} waiting for a blink" }
        if why.contains("face seen, distance") { return "Not recognized" }
        if why.hasPrefix("match ") { return "Recognizing\u{2026}" }
        if why.contains("no comparable descriptor") { return "Can't get a clear read on your face" }
        return "Checking\u{2026}"
    }
}

struct TestPanel: View {
    @StateObject private var model = TestModel()

    var body: some View {
        VStack(spacing: 18) {
            CameraPreview(feed: model.feed, highlight: model.phase == .matched ? .green : nil)

            Group {
                switch model.phase {
                case .looking:
                    Text(model.detail).foregroundStyle(.secondary)
                case .matched:
                    Label("Recognized", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                case .timedOut:
                    Label("Not recognized", systemImage: "xmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                }
            }
            .frame(minHeight: 28)

            if model.phase != .looking {
                Button("Test Again") { model.run() }
            }
        }
        .onAppear {
            model.feed.start()
            model.run()
        }
        .onDisappear { model.stop() }
    }
}
