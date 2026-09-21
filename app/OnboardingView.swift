import SwiftUI

/// First-run steps, shown one at a time.
enum OnboardingStep: Int, CaseIterable {
    case welcome, camera, enroll, strictness, password, lockScreen, done
}

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var started = false
    @AppStorage("onboardingChoseStrictness") private var choseStrictness = false
    @State private var password = ""
    @State private var passwordProblem: String?
    @State private var savingPassword = false

    /// The current step, derived from what is already set up.
    private var step: OnboardingStep {
        let fresh = model.camera != .authorized && !model.isEnrolled
        if fresh && !started { return .welcome }
        if model.camera != .authorized { return .camera }
        if !model.isEnrolled { return .enroll }
        if !choseStrictness { return .strictness }
        if !model.passwordSaved { return .password }
        if !model.lockScreenWired { return .lockScreen }
        return .done
    }

    var body: some View {
        VStack(spacing: 20) {
            ProgressDots(step: step)

            switch step {
            case .welcome: welcome
            case .camera: camera
            case .enroll: enroll
            case .strictness: strictness
            case .password: passwordStep
            case .lockScreen: lockScreen
            case .done: finished
            }

            Group {
                if let error = model.actionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }
            .frame(height: 36)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcome: some View {
        Page {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("Unlock your Mac with your face")
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 14) {
                Point(icon: "return", text: "Press Return on the empty password field and MacID checks your face.")
                Point(icon: "key", text: "If MacID fails, your password still works.")
                Point(icon: "photo", text: "A good photo could unlock it. Turn on Require a blink to stop that.")
            }
            .fixedSize()
        } button: {
            Button("Get Started") { started = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var camera: some View {
        Page {
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
            } else {
                Text("MacID looks for your face when your Mac is locked. macOS can't "
                     + "ask for permission at the lock screen, so it asks now.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
        } button: {
            if model.camera == .denied {
                Button("Open Camera Settings") { CameraAccess.openSettingsPane() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
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
            EnrollPanel(pinsButton: true) { model.refresh() }
                .frame(maxHeight: .infinity)
        }
    }

    private var strictness: some View {
        Page {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)

            Text("How strict should MacID be?").font(.largeTitle.weight(.semibold))

            SensitivityControl()
                .frame(maxWidth: 420)
        } button: {
            Button("Continue") { choseStrictness = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var passwordStep: some View {
        Page {
            Image(systemName: "key")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)

            Text("Enter your Mac password").font(.largeTitle.weight(.semibold))

            Text("So your saved passwords keep working. It never leaves this Mac.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .onSubmit(savePassword)

            if let passwordProblem {
                Label(passwordProblem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        } button: {
            if savingPassword {
                ProgressView().controlSize(.large)
            } else {
                Button("Continue", action: savePassword)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
    }

    private func savePassword() {
        guard !password.isEmpty, !savingPassword else { return }
        savingPassword = true
        Task {
            passwordProblem = await model.savePassword(password)
            savingPassword = false
            if passwordProblem == nil { password = "" }
        }
    }

    private var lockScreen: some View {
        Group {
            if !model.hasFullDiskAccess {
                fullDiskAccess
            } else {
                turnOn
            }
        }
    }

    private var fullDiskAccess: some View {
        Page {
            Image(systemName: "lock.shield")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)

            Text("Allow MacID to change the lock screen")
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("macOS needs you to turn on Full Disk Access for MacID before it can "
                 + "add itself to the lock screen.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Text("Turn on MacID in the list. If macOS asks to quit and reopen, let it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } button: {
            Button("Open System Settings") { FullDiskAccess.openSettingsPane() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var turnOn: some View {
        Page {
            Image(systemName: "lock.open.display")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)

            Text("Turn on face unlock").font(.largeTitle.weight(.semibold))

            Text("MacID adds itself to the lock screen. If it ever can't "
                 + "recognize you, you type your password as usual.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        } button: {
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
        Page {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.green)
            Text("You're all set").font(.largeTitle.weight(.semibold))
            Text("Lock your Mac, look at it, and press Return.")
                .foregroundStyle(.secondary)
        } button: {
            Button("Done") { model.onboardingFinished = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// A setup step: its content centred in the space above, its button pinned to the bottom.
private struct Page<Content: View, Action: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let button: Action

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
            button.frame(height: OnboardingLayout.buttonHeight)
        }
        .frame(maxHeight: .infinity)
    }
}

enum OnboardingLayout {
    static let buttonHeight: CGFloat = 44
}

private struct Point: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundStyle(.tint)
                .frame(width: 26, alignment: .center)
                .padding(.top, 1)
            Text(text)
        }
    }
}

private struct ProgressDots: View {
    let step: OnboardingStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases.indices, id: \.self) { index in
                Capsule()
                    .fill(index <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: index == step.rawValue ? 22 : 8, height: 8)
                    .animation(.snappy, value: step.rawValue)
            }
        }
    }
}
