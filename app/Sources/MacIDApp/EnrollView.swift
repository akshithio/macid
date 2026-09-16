import SwiftUI
import AppKit
import MacIDCore

/// Guided enrollment with a live preview.
///
/// The preview is not decoration. Enrollment quality is the single biggest
/// determinant of whether this works day to day, and the most common failure —
/// backlit, half out of frame, too dark — is obvious the moment you can see
/// what the camera sees.
@MainActor
final class EnrollModel: ObservableObject {

    enum Phase: Equatable {
        case idle
        case capturing(step: Int, total: Int, prompt: String)
        case done(samples: Int, threshold: Float, spread: Float)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var preview: CGImage?
    @Published var faceVisible = false

    private let camera = Camera()
    private var descriptors: [FaceEngine.Descriptor] = []
    private var capturing = false

    private let prompts = [
        "Look straight at the camera",
        "Hold still",
        "Tilt your head slightly left",
        "Tilt your head slightly right",
        "Chin up a little",
        "Chin down a little",
        "Look straight again",
        "Last one",
    ]

    func startPreview() {
        guard !camera.isRunning else { return }
        do {
            try camera.start { [weak self] image in
                guard let self else { return }
                let seen = (try? FaceEngine.analyze(image, wantDescriptor: false)) != nil
                Task { @MainActor in
                    self.preview = image
                    self.faceVisible = seen
                }
            }
        } catch {
            Task { @MainActor in self.phase = .failed("\(error)") }
        }
    }

    func stopPreview() {
        camera.stop()
        preview = nil
    }

    func enroll(total: Int = 8) {
        guard !capturing else { return }
        capturing = true
        descriptors = []

        Task.detached { [weak self] in
            guard let self else { return }
            var attempts = 0

            while await self.descriptors.count < total && attempts < total * 5 {
                attempts += 1
                let index = await self.descriptors.count
                let prompt = await self.prompts[min(index, self.prompts.count - 1)]
                await MainActor.run {
                    self.phase = .capturing(step: index + 1, total: total, prompt: prompt)
                }

                try? await Task.sleep(nanoseconds: 900_000_000)

                guard let frame = await self.preview else { continue }
                guard let detection = try? FaceEngine.analyze(frame),
                      let descriptor = detection.descriptor else { continue }
                await MainActor.run { self.descriptors.append(descriptor) }
            }

            await self.finish(total: total)
        }
    }

    private func finish(total: Int) async {
        let captured = descriptors
        guard captured.count >= 3 else {
            await MainActor.run {
                self.phase = .failed("Only captured \(captured.count) of \(total) samples. More even lighting usually fixes this.")
                self.capturing = false
            }
            return
        }

        // Calibrate from the spread among your own samples. A threshold that is
        // not derived from your face is just a guess: too tight and you never
        // match, too loose and the gate stops meaning anything.
        var spreads: [Float] = []
        for i in 0..<captured.count {
            for j in (i + 1)..<captured.count {
                if let d = FaceEngine.distance(from: captured[i], to: [captured[j]]) {
                    spreads.append(d)
                }
            }
        }
        let worst = spreads.max() ?? 0.4
        let threshold = min(max(worst * 1.25, 0.30), 0.75)

        var config = Config.load()
        config.threshold = threshold

        do {
            try Enrollment.save(captured)
            try config.save()
            await MainActor.run {
                self.phase = .done(samples: captured.count, threshold: threshold, spread: worst)
                self.capturing = false
            }
        } catch {
            await MainActor.run {
                self.phase = .failed("Could not save: \(error)")
                self.capturing = false
            }
        }
    }
}

struct EnrollView: View {
    @StateObject private var model = EnrollModel()
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            preview
                .frame(width: 360, height: 270)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(model.faceVisible ? Color.green : Color.secondary.opacity(0.4),
                                      lineWidth: 2)
                )

            status

            controls
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { model.startPreview() }
        .onDisappear { model.stopPreview() }
    }

    @ViewBuilder
    private var preview: some View {
        if let image = model.preview {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                // The camera is not a mirror, but people expect one.
                .scaleEffect(x: -1, y: 1)
        } else {
            ZStack {
                Color.black.opacity(0.85)
                ProgressView()
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .idle:
            Text(model.faceVisible ? "Face detected — ready when you are."
                                   : "Center your face in the frame.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .capturing(let step, let total, let prompt):
            VStack(spacing: 6) {
                Text(prompt).font(.headline)
                ProgressView(value: Double(step), total: Double(total))
                Text("\(step) of \(total)").font(.caption).foregroundStyle(.secondary)
            }
        case .done(let samples, let threshold, let spread):
            VStack(spacing: 4) {
                Label("Enrolled \(samples) samples", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
                Text(String(format: "Threshold %.3f (your samples vary by %.3f)", threshold, spread))
                    .font(.caption).foregroundStyle(.secondary)
                if spread > 0.5 {
                    Text("That spread is high. Re-enrolling in even lighting will make recognition more reliable.")
                        .font(.caption).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack {
            Button("Close") {
                model.stopPreview()
                app.refresh()
                dismiss()
            }
            Spacer()
            switch model.phase {
            case .done:
                Button("Re-enroll") { model.enroll() }
            case .capturing:
                Button("Capturing…") {}.disabled(true)
            default:
                Button("Start Enrollment") { model.enroll() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.faceVisible)
            }
        }
    }
}
