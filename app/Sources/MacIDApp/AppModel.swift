import AppKit
import SwiftUI
import MacIDCore

/// Everything the window and the menu show, and the actions behind them.
///
/// The app also hosts the agent. It is the process that holds the camera
/// permission and starts at login, so unlocking does not depend on a separate
/// background binary whose permissions the user cannot see.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum AgentHost: Equatable {
        /// Running inside this app.
        case app
        /// Another process is serving the socket — a leftover launchd agent
        /// from a build that predates the app hosting it. Installing clears it.
        case background
        case stopped(String?)
    }

    @Published private(set) var sampleCount = 0
    @Published private(set) var lockScreenWired = false
    @Published private(set) var lockScreenProblem: String?
    @Published private(set) var camera = CameraAccess.status
    @Published private(set) var agentHost: AgentHost = .stopped(nil)
    @Published private(set) var launchAtLogin = LoginItem.isEnabled
    @Published private(set) var config = Config.load()
    @Published private(set) var busy = false
    @Published var actionError: String?

    /// Diagnostics. `state` is cheap and refreshes on the timer; `cameraReport`
    /// opens the camera, so it only runs when asked for.
    @Published private(set) var checks: [Diagnostics.Check] = []
    @Published private(set) var cameraChecks: [Diagnostics.Check] = []
    @Published private(set) var runningCameraCheck = false

    @AppStorage("onboardingFinished") var onboardingFinished = false

    private let agent = Agent(requestsCameraAccess: false)
    private var timer: Timer?

    var isEnrolled: Bool { sampleCount > 0 }
    var agentRunning: Bool { agentHost == .app || agentHost == .background }
    var isReady: Bool { isEnrolled && lockScreenWired && camera == .authorized && agentRunning }

    var statusSummary: String {
        if isReady { return "Face unlock is on" }
        if camera != .authorized { return "Needs camera access" }
        if !isEnrolled { return "No face enrolled" }
        if !lockScreenWired { return lockScreenProblem == nil ? "Lock screen not set up" : "Lock screen needs repair" }
        return "Not running"
    }

    private init() {}

    func bootstrap() {
        refresh()
        // An install that already works needs no onboarding.
        if isReady { onboardingFinished = true }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func shutdown() {
        agent.stop()
    }

    func refresh() {
        sampleCount = (try? Enrollment.load().count) ?? 0
        camera = CameraAccess.status
        config = Config.load()
        launchAtLogin = LoginItem.isEnabled

        if let path = LockScreen.wiredModulePath {
            lockScreenProblem = LockScreen.rootOnlyChainProblem(path)
            lockScreenWired = lockScreenProblem == nil
        } else {
            lockScreenProblem = nil
            lockScreenWired = false
        }

        checks = Diagnostics.state()
        ensureAgent()
    }

    /// Competes with the agent for the camera, so it runs off the main actor
    /// and only on demand.
    func runCameraCheck() async {
        runningCameraCheck = true
        defer { runningCameraCheck = false }
        cameraChecks = await Task.detached(priority: .userInitiated) {
            Diagnostics.cameraReport()
        }.value
    }

    /// Exactly one agent should be serving the socket. If nothing is — the
    /// launchd copy was removed, or it crashed — this app takes over.
    private func ensureAgent() {
        if agent.isRunning {
            agentHost = .app
            return
        }
        do {
            try agent.start()
            agentHost = .app
        } catch Agent.AgentError.alreadyRunning {
            agentHost = .background
        } catch {
            agentHost = .stopped("\(error)")
        }
    }

    // MARK: - Actions

    func requestCamera() async {
        _ = await CameraAccess.request()
        refresh()
    }

    func setRequireBlink(_ on: Bool) {
        var updated = Config.load()
        updated.liveness = on ? .blink : .attention
        try? updated.save()
        refresh()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.setEnabled(on)
        } catch {
            actionError = "macOS did not allow MacID to change its login item: \(error.localizedDescription)"
        }
        refresh()
    }

    func turnOnLockScreen() async {
        busy = true
        defer { busy = false }
        actionError = nil

        switch await SystemInstaller.install() {
        case .done:
            // The app is now the agent's host; make sure it is back after a
            // restart. Ad-hoc builds can be refused here, which is not fatal.
            if !LoginItem.isEnabled { try? LoginItem.setEnabled(true) }
        case .cancelled:
            break
        case .failed(let message):
            actionError = message
        }
        refresh()
    }

    func turnOffLockScreen() async {
        busy = true
        defer { busy = false }
        actionError = nil

        switch await SystemInstaller.uninstall() {
        case .done, .cancelled:
            break
        case .failed(let message):
            actionError = message
        }
        refresh()
    }

    func deleteFaceData() {
        try? Enrollment.clear()
        refresh()
    }
}
