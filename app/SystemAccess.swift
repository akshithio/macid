import AppKit
import AVFoundation
import ServiceManagement
import MacIDCore

enum CameraAccess {
    enum Status { case notDetermined, authorized, denied }

    static var status: Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    static func openSettingsPane() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }
}

/// Full Disk Access, which macOS 26 requires before /etc/pam.d can be changed.
enum FullDiskAccess {
    /// Probed by opening the system TCC database; nothing is read.
    static var isGranted: Bool {
        FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db") != nil
    }

    static func openSettingsPane() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsUserApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Runs `macid-helper` through the macOS administrator prompt.
enum SystemInstaller {

    enum Outcome {
        case done
        case cancelled
        case failed(String)
        case needsFullDiskAccess
    }

    /// Bundle directory holding the helper and the PAM module.
    private static var helpers: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
    }

    private static var helper: URL { helpers.appendingPathComponent("macid-helper") }

    static var isBundled: Bool {
        FileManager.default.isExecutableFile(atPath: helper.path)
    }

    static func install() async -> Outcome {
        guard isBundled else {
            return .failed("Run MacID from MacID.app — the helper it installs is part of the app bundle.")
        }
        let module = helpers.appendingPathComponent("pam_macid.so").path
        let script = """
        set -e
        install -d -o root -g wheel -m 755 /opt/macid /opt/macid/lib
        install -o root -g wheel -m 644 \(quoted(module)) /opt/macid/lib/pam_macid.so
        \(quoted(helper.path)) install --user \(quoted(NSUserName()))
        """
        return await runAsAdministrator(script)
    }

    static func uninstall() async -> Outcome {
        guard isBundled else {
            return .failed("Run MacID from MacID.app to turn face unlock off.")
        }
        return await runAsAdministrator(
            "\(quoted(helper.path)) uninstall --user \(quoted(NSUserName()))")
    }

    static var bundledModule: String { helpers.appendingPathComponent("pam_macid.so").path }

    /// Atomically replaces the installed PAM module with the bundled one.
    static func updateModule() async -> Outcome {
        guard isBundled else { return .failed("Run MacID from MacID.app.") }
        let script = """
        set -e
        install -o root -g wheel -m 644 \(quoted(bundledModule)) /opt/macid/lib/.pam_macid.so.new
        mv -f /opt/macid/lib/.pam_macid.so.new /opt/macid/lib/pam_macid.so
        """
        return await runAsAdministrator(script)
    }

    /// Unwires the lock screen, then removes /opt/macid and the app bundle.
    static func purge() async -> Outcome {
        guard isBundled else {
            return .failed("Run MacID from MacID.app to uninstall it.")
        }
        let app = Bundle.main.bundleURL.path
        return await runAsAdministrator(
            "\(quoted(helper.path)) purge --user \(quoted(NSUserName())) --app \(quoted(app))")
    }

    private static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a shell command as root via osascript in a child process. Uses the saved
    /// Mac password when there is one, so macOS doesn't ask for it again.
    private static func runAsAdministrator(_ shell: String) async -> Outcome {
        if let password = StoredPassword.load() {
            let outcome = await runOsascript(shell, password: password)
            if case .failed = outcome {} else { return outcome }
        }
        return await runOsascript(shell, password: nil)
    }

    private static func runOsascript(_ shell: String, password: String?) async -> Outcome {
        var source = "do shell script \(appleScriptString(shell))"
        if let password {
            source += " user name \(appleScriptString(NSUserName())) password \(appleScriptString(password))"
        }
        source += " with administrator privileges"

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-"]
            let stdin = Pipe()
            process.standardInput = stdin
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = Pipe()
            process.terminationHandler = { p in
                let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                                     as: UTF8.self)
                if p.terminationStatus == 0 {
                    continuation.resume(returning: .done)
                } else if message.contains("-128") {
                    continuation.resume(returning: .cancelled)
                } else {
                    if message.contains("/etc/pam.d") && message.contains("Operation not permitted") {
                        continuation.resume(returning: .needsFullDiskAccess)
                    } else {
                        continuation.resume(returning: .failed(cleaned(message)))
                    }
                }
            }
            do {
                try process.run()
                stdin.fileHandleForWriting.write(Data(source.utf8))
                try? stdin.fileHandleForWriting.close()
            } catch {
                continuation.resume(returning: .failed(error.localizedDescription))
            }
        }
    }

    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Strips osascript's error offset prefix.
    private static func cleaned(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "execution error: ") {
            return String(trimmed[range.upperBound...])
        }
        return trimmed.isEmpty ? "The installer exited with an error." : trimmed
    }
}
