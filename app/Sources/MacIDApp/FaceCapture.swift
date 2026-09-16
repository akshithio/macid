import SwiftUI
import MacIDCore

/// Live camera feed shared by enrollment and testing.
///
/// Showing the preview is not decoration: the usual reasons recognition works
/// badly — backlit, half out of frame, too dark — are obvious the moment you can
/// see what the camera sees.
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
                // Face detection on every frame would starve the preview; a few
                // times a second is plenty for a "face found" indicator.
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
                    // A camera is not a mirror, but a preview that moves the
                    // wrong way is disorienting.
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

// MARK: - Enrollment

@MainActor
final class EnrollModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case capturing(step: Int, total: Int, prompt: String)
        case done(Calibration.Result)
        case failed(String)

        static func == (a: Phase, b: Phase) -> Bool {
            switch (a, b) {
            case (.ready, .ready): return true
            case let (.capturing(x, y, z), .capturing(p, q, r)): return x == p && y == q && z == r
            case let (.done(x), .done(y)): return x.samples == y.samples && x.threshold == y.threshold
            case let (.failed(x), .failed(y)): return x == y
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .ready
    let feed = CameraFeed()

    private let total = 8
    private let prompts = [
        "Look straight at the camera",
        "Hold still",
        "Turn your head slightly left",
        "Turn your head slightly right",
        "Tilt your chin up a little",
        "Tilt your chin down a little",
        "Look straight again",
        "One more",
    ]

    var isCapturing: Bool {
        if case .capturing = phase { return true }
        return false
    }

    func begin() {
        guard !isCapturing else { return }
        phase = .capturing(step: 1, total: total, prompt: prompts[0])

        Task {
            // Let exposure settle before the first sample: early frames are dark.
            _ = await Task.detached { [camera = feed.camera] in camera.warmUp() }.value

            var samples: [Calibration.Sample] = []
            var attempts = 0
            while samples.count < total && attempts < total * 5 {
                attempts += 1
                phase = .capturing(step: samples.count + 1, total: total,
                                   prompt: prompts[min(samples.count, prompts.count - 1)])
                try? await Task.sleep(for: .milliseconds(900))

                guard let frame = feed.camera.latestFrame else { continue }
                let sample = await Task.detached {
                    try? Calibration.Sample(FaceEngine.analyze(frame))
                }.value
                if let sample { samples.append(sample) }
            }

            do {
                phase = .done(try Calibration.commit(samples))
            } catch {
                phase = .failed("\(error)")
            }
        }
    }
}

struct EnrollPanel: View {
    @StateObject private var model = EnrollModel()
    var onFinished: () -> Void = {}

    var body: some View {
        VStack(spacing: 18) {
            CameraPreview(feed: model.feed, highlight: highlight)

            status.frame(minHeight: 52)

            switch model.phase {
            case .ready:
                Button("Start") { model.begin() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.feed.faceVisible)
            case .capturing:
                Button("Capturing\u{2026}") {}
                    .controlSize(.large)
                    .disabled(true)
            case .done:
                Button("Continue") { onFinished() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            case .failed:
                Button("Try Again") { model.begin() }
                    .controlSize(.large)
            }
        }
        .onAppear { model.feed.start() }
        .onDisappear { model.feed.stop() }
    }

    private var highlight: Color? {
        switch model.phase {
        case .done: return .green
        case .capturing: return .accentColor
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
        case .capturing(let step, let total, let prompt):
            VStack(spacing: 8) {
                Text(prompt).font(.headline)
                ProgressView(value: Double(step - 1), total: Double(total))
                    .frame(width: 220)
            }
        case .done(let result):
            VStack(spacing: 4) {
                Label("Face enrolled", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                if result.isNoisy {
                    Text("Lighting was uneven. Re-enrolling in even light will make recognition more reliable.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Test

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
                case .rejected(let why):
                    detail = why
                }
            }
            if !Task.isCancelled { phase = .timedOut }
        }
    }

    func stop() {
        task?.cancel()
        feed.stop()
    }

    /// The recognizer's status strings are written for logs; soften the common ones.
    private static func humane(_ why: String) -> String {
        if why.contains("no face") { return "Look at the camera" }
        if why.contains("faces in frame") { return "Only one person should be in view" }
        if why.contains("eyes closed") { return "Keep your eyes open and on the screen" }
        if why.contains("blink") { return "Recognized \u{2014} waiting for a blink" }
        if why.contains("distance") { return "Checking\u{2026}" }
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
