import SwiftUI

/// First-run steps, shown one at a time. Only the welcome step is informational;
/// every other step is something the user does.
enum OnboardingStep: Int, CaseIterable {
    case welcome, enroll, password, lockScreen
}

struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var started = false
    @State private var password = ""
    @State private var passwordProblem: String?
    @State private var savingPassword = false

    /// The current step, derived from what is already set up.
    private var step: OnboardingStep {
        let fresh = model.camera != .authorized && !model.isEnrolled
        if fresh && !started { return .welcome }
        if model.camera != .authorized { return .welcome }
        if !model.isEnrolled { return .enroll }
        if !model.passwordSaved { return .password }
        return .lockScreen
    }

    var body: some View {
        VStack(spacing: 20) {
            ProgressDots(step: step)

            switch step {
            case .welcome: model.camera == .denied ? AnyView(cameraDenied) : AnyView(welcome)
            case .enroll: AnyView(enroll)
            case .password: AnyView(passwordStep)
            case .lockScreen: AnyView(lockScreen)
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
        .overlay {
            if step == .lockScreen && model.needsFullDiskAccess {
                FullDiskAccessOverlay()
            }
        }
        .onChange(of: model.lockScreenWired) { _, wired in
            if wired {
                FullDiskAccessGuide.hide()
                model.onboardingFinished = true
            }
        }
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
            Button("Get Started") {
                started = true
                Task { await model.requestCamera() }
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var cameraDenied: some View {
        Page {
            Image(systemName: "web.camera")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)

            Text("Allow camera access").font(.largeTitle.weight(.semibold))

            Text("Camera access for MacID is turned off. Turn on **MacID** under "
                 + "Camera in Privacy & Security, then come back.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        } button: {
            Button("Open Camera Settings") { CameraAccess.openSettingsPane() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
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

    /// Adds MacID to the lock screen as soon as this step appears; setting up means wanting it on.
    private var lockScreen: some View {
        Page {
            Image(systemName: "lock.open.display")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)

            Text("Turning on face unlock").font(.largeTitle.weight(.semibold))

            Text("MacID is adding itself to the lock screen. If it ever can't "
                 + "recognize you, you type your password as usual.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        } button: {
            if model.busy || model.needsFullDiskAccess {
                ProgressView().controlSize(.large)
            } else {
                Button("Try Again") { Task { await model.turnOnLockScreen() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .task { await model.turnOnLockScreen() }
        .onChange(of: model.hasFullDiskAccess) { _, granted in
            guard granted else { return }
            FullDiskAccessGuide.hide()
            NSApp.activate(ignoringOtherApps: true)
            Task { await model.turnOnLockScreen() }
        }
    }
}

/// Greys out the setup window while the user grants Full Disk Access in System Settings.
private struct FullDiskAccessOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.35))

            VStack(spacing: 14) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tint)

                Text("Allow Full Disk Access")
                    .font(.title2.weight(.semibold))

                Text("macOS protects the lock screen's settings. Drag MacID into the "
                     + "Full Disk Access list in System Settings, and setup carries on by itself.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Show Me Again") { FullDiskAccessGuide.show() }
                    .controlSize(.large)
                    .padding(.top, 4)
            }
            .padding(28)
            .frame(width: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .onAppear { FullDiskAccessGuide.show() }
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
