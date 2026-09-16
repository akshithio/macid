import SwiftUI
import MacIDCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var config = Config.load()
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("Recognition") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Match threshold")
                        Spacer()
                        Text(String(format: "%.3f", config.threshold))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.threshold, in: 0.20...0.80)
                    Text("Lower is stricter. Enrollment calibrates this from how much your own samples vary — changing it by hand is usually a step backwards.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Stepper("Frames required: \(config.requiredFrames)",
                        value: $config.requiredFrames, in: 1...10)
            }

            Section("Liveness") {
                Toggle("Require a blink", isOn: $config.requireBlink)
                Text(config.requireBlink
                     ? "A still photo of you cannot blink, so it cannot unlock. This will not stop a video."
                     : "Turned off, a printed photo or a picture on a phone screen will unlock your Mac.")
                    .font(.caption)
                    .foregroundStyle(config.requireBlink ? Color.secondary : Color.orange)
            }

            Section("Scanning") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Give up after")
                        Spacer()
                        Text("\(Int(config.scanTimeout))s").foregroundStyle(.secondary)
                    }
                    Slider(value: $config.scanTimeout, in: 10...180, step: 5)
                    Text("How long the camera stays on after the screen locks before shutting off. The indicator light is on for exactly this window.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Enrollment") {
                HStack {
                    Text(model.isEnrolled ? "\(model.enrolledSamples) samples stored"
                                          : "No face enrolled")
                    Spacer()
                    Button("Delete", role: .destructive) {
                        model.clearEnrollment()
                    }
                    .disabled(!model.isEnrolled)
                }

                HStack {
                    Button(testing ? "Testing…" : "Test Recognition Now") { runTest() }
                        .disabled(testing || !model.isEnrolled)
                    if let testResult {
                        Text(testResult).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Data") {
                LabeledContent("Stored at") {
                    Text(Paths.dir.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onChange(of: config) { _, newValue in model.save(newValue) }
    }

    /// Runs a live recognition pass so you can confirm the current settings
    /// actually work before relying on them at the lock screen.
    private func runTest() {
        testing = true
        testResult = nil

        Task.detached {
            guard let enrolled = try? Enrollment.load() else {
                await MainActor.run {
                    testResult = "nothing enrolled"
                    testing = false
                }
                return
            }

            let recognizer = Recognizer(config: Config.load(), enrolled: enrolled)
            let camera = Camera()
            let deadline = Date().addingTimeInterval(20)
            let box = ResultBox()

            do {
                try camera.start { image in
                    guard !box.isDone else { return }
                    if case .matched(let distance, _) = recognizer.consider(image) {
                        box.finish(String(format: "match, distance %.3f", distance))
                    }
                }
            } catch {
                await MainActor.run {
                    testResult = "\(error)"
                    testing = false
                }
                return
            }

            while !box.isDone && Date() < deadline {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            camera.stop()

            let outcome = box.value ?? "no match in 20s — look at the camera and blink"
            await MainActor.run {
                testResult = outcome
                testing = false
            }
        }
    }
}

/// Small thread-safe box so the camera callback can report back into the async
/// test without tripping over actor isolation.
final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var isDone: Bool {
        lock.lock(); defer { lock.unlock() }
        return stored != nil
    }

    var value: String? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func finish(_ v: String) {
        lock.lock(); defer { lock.unlock() }
        if stored == nil { stored = v }
    }
}
