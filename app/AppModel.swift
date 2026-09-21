import AppKit
import SwiftUI
import MacIDCore

/// State and actions behind the window and the menu. Also hosts the agent.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum AgentHost: Equatable {
        /// The agent runs inside this app.
        case app
        /// Another process, such as a leftover launchd agent, is serving the socket.
        case background
        case stopped(String?)
    }

    @Published private(set) var sampleCount = 0
    @Published private(set) var faces: [Enrollment.Face] = []
    @Published private(set) var lockScreenWired = false
    @Published private(set) var lockScreenProblem: String?
    @Published private(set) var camera = CameraAccess.status
    @Published private(set) var agentHost: AgentHost = .stopped(nil)
    @Published private(set) var launchAtLogin = LoginItem.isEnabled
    @Published private(set) var config = Config.load()
    @Published private(set) var passwordSaved = StoredPassword.isStored
    @Published private(set) var moduleOutdated = false
    /// Set when macOS refused a lock screen change for lack of Full Disk Access.
    @Published private(set) var needsFullDiskAccess = false
    @Published private(set) var hasFullDiskAccess = FullDiskAccess.isGranted
    @Published private(set) var busy = false
    @Published var actionError: String?

    @Published private(set) var collectingDiagnostics = false
    @Published private(set) var diagnosticsCopied = false

    @AppStorage("onboardingFinished") var onboardingFinished = false

    private let agent = Agent(requestsCameraAccess: false)
    private var timer: Timer?

    var isEnrolled: Bool { sampleCount > 0 }
    var agentRunning: Bool { agentHost == .app || agentHost == .background }
    var isReady: Bool {
        isEnrolled && lockScreenWired && camera == .authorized && agentRunning && passwordSaved
    }

    var statusSummary: String {
        if isReady { return "Face unlock is on" }
        if camera != .authorized { return "Needs camera access" }
        if !isEnrolled { return "No face enrolled" }
        if !passwordSaved { return "Needs your Mac password" }
        if !lockScreenWired { return lockScreenProblem == nil ? "Lock screen not set up" : "Lock screen needs repair" }
        return "Not running"
    }

    private init() {}

    func bootstrap() {
        refresh()
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
        faces = Enrollment.faces()
        camera = CameraAccess.status
        config = Config.load()
        passwordSaved = StoredPassword.isStored
        hasFullDiskAccess = FullDiskAccess.isGranted
        if needsFullDiskAccess && hasFullDiskAccess { needsFullDiskAccess = false }
        if hasFullDiskAccess && FullDiskAccessGuide.isShown { FullDiskAccessGuide.hide() }
        moduleOutdated = lockScreenWired && SystemInstaller.isBundled
            && LockScreen.moduleIsOutdated(comparedTo: SystemInstaller.bundledModule)
        launchAtLogin = LoginItem.isEnabled

        if let path = LockScreen.wiredModulePath {
            lockScreenProblem = LockScreen.rootOnlyChainProblem(path)
            lockScreenWired = lockScreenProblem == nil
        } else {
            lockScreenProblem = nil
            lockScreenWired = false
        }

        ensureAgent()
    }

    func copyDiagnostics() async {
        collectingDiagnostics = true
        defer { collectingDiagnostics = false }

        let report = await Task.detached(priority: .userInitiated) {
            Diagnostics.report()
        }.value

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)

        diagnosticsCopied = true
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        diagnosticsCopied = false
    }

    /// Starts the agent in this app if nothing is serving the socket.
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

    func requestCamera() async {
        _ = await CameraAccess.request()
        refresh()
    }

    /// Returns whether the camera is usable, requesting access first if needed.
    func ensureCamera() async -> Bool {
        switch camera {
        case .authorized:
            return true
        case .notDetermined:
            await requestCamera()
            return camera == .authorized
        case .denied:
            CameraAccess.openSettingsPane()
            actionError = "MacID needs camera access to see you. Turn it on in "
                + "System Settings > Privacy & Security > Camera, then try again."
            return false
        }
    }

    /// 0 is strictest, 1 most forgiving. Also writes the threshold.
    func setSensitivity(_ value: Double) {
        var updated = Config.load()
        updated.sensitivity = value
        updated.applySensitivity()
        try? updated.save()
        refresh()
    }

    /// Verifies the password against the account and saves it.
    /// Returns the error to show, or nil on success.
    func savePassword(_ password: String) async -> String? {
        let result: String? = await Task.detached(priority: .userInitiated) {
            do {
                try StoredPassword.save(password)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        refresh()
        return result
    }

    func forgetPassword() {
        StoredPassword.clear()
        refresh()
    }

    func removeFace(_ id: UUID) {
        try? Enrollment.remove(id: id)
        refresh()
    }

    func setWarmWithDisplay(_ on: Bool) {
        var updated = Config.load()
        updated.warmWithDisplay = on
        try? updated.save()
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
            if !LoginItem.isEnabled { try? LoginItem.setEnabled(true) }
        case .cancelled:
            break
        case .needsFullDiskAccess:
            needsFullDiskAccess = true
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
        case .done:
            StoredPassword.clear()
        case .cancelled:
            break
        case .needsFullDiskAccess:
            needsFullDiskAccess = true
        case .failed(let message):
            actionError = message
        }
        refresh()
    }

    /// Replaces the installed PAM module with the bundled one.
    func updateModule() async {
        busy = true
        defer { busy = false }
        actionError = nil
        if case .failed(let message) = await SystemInstaller.updateModule() {
            actionError = message
        }
        refresh()
    }

    /// Removes MacID from this Mac entirely, then quits.
    func uninstallEverything() async {
        busy = true
        defer { busy = false }
        actionError = nil

        switch await SystemInstaller.purge() {
        case .cancelled:
            return
        case .failed(let message):
            actionError = message
            refresh()
            return
        case .needsFullDiskAccess:
            needsFullDiskAccess = true
            refresh()
            return
        case .done:
            break
        }

        try? LoginItem.setEnabled(false)
        try? Enrollment.clear()
        try? FileManager.default.removeItem(at: Paths.dir)

        agent.stop()
        NSApp.terminate(nil)
    }
}
