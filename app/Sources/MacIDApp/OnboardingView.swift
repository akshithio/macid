import SwiftUI

/// First run. Four things have to be true before the lock screen will open for
/// your face — camera access, an enrolled face, the lock screen set up, and
/// the app running — and you only ever see the one you are on.
enum OnboardingStep: Int, CaseIterable {
    case welcome, camera, enroll, lockScreen, done

    var dotIndex: Int {
        switch self {
        case .welcome, .camera: 0
        case .enroll: 1
        case .lockScreen: 2
        case .done: 3
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var started = false

    private var step: OnboardingStep {
        if !started && model.camera != .authorized && !model.isEnrolled { return .welcome }
        if model.camera != .authorized { return .camera }
        if !model.isEnrolled { return .enroll }
        if !model.lockScreenWired { return .lockScreen }
        return .done
    }

    var body: some View {
        VStack(spacing: 28) {
            ProgressDots(step: step)

            switch step {
            case .welcome: welcome
            case .camera: camera
            case .enroll: enroll
            case .lockScreen: lockScreen
            case .done: finished
            }

            if let error = model.actionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("Unlock your Mac with your face")
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("Wake your Mac, look at it, and press Return. Recognition runs "
                 + "entirely on this Mac, and your password always still works.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button("Get Started") { started = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var camera: some View {
        VStack(spacing: 20) {
            Image(systemName: "web.camera")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)

            Text("Allow camera access").font(.largeTitle.weight(.semibold))

            if model.camera == .denied {
                Text("Camera access for MacID is turned off. Turn on **MacID** under "
                     + "Camera in Privacy & Security, then come back.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

                Button("Open Camera Settings") { CameraAccess.openSettingsPane() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                Text("This window updates by itself once you flip the switch.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("MacID looks for your face when your Mac is locked. macOS can't "
                     + "ask for permission at the lock screen, so it asks now.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)

                Button("Continue") { Task { await model.requestCamera() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var enroll: some View {
        VStack(spacing: 16) {
            Text("Set up your face").font(.largeTitle.weight(.semibold))
            Text("Follow the prompts for about ten seconds.")
                .foregroundStyle(.secondary)
            EnrollPanel { model.refresh() }
        }
    }

    private var lockScreen: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.open.display")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)

            Text("Turn on face unlock").font(.largeTitle.weight(.semibold))

            Text("MacID adds itself to the lock screen, so macOS will ask for "
                 + "your password once. If MacID ever can't recognize you, you "
                 + "just type your password as usual.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            if model.busy {
                ProgressView().controlSize(.large)
            } else {
                Button("Turn On Face Unlock") { Task { await model.turnOnLockScreen() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var finished: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text("You're all set").font(.largeTitle.weight(.semibold))
            Text("Lock your Mac, look at it, and press Return.")
                .foregroundStyle(.secondary)
            Button("Done") { model.onboardingFinished = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct ProgressDots: View {
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0 ..< 4, id: \.self) { index in
                Capsule()
                    .fill(index <= step.dotIndex ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: index == step.dotIndex ? 22 : 8, height: 8)
                    .animation(.snappy, value: step.dotIndex)
            }
        }
    }
}
