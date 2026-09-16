import AppKit
import AVFoundation
import ServiceManagement
import MacIDCore

/// Camera permission for the app itself. The agent runs inside this process,
/// so this is the grant the lock screen depends on — and it has to be given
/// while the user is at the desk, because no prompt can appear at the lock
/// screen.
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

/// Starts MacID at login via SMAppService. The agent lives in the app, so if
/// the app is not running, face unlock is not running.
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

/// Changes to the lock screen need root. The app never holds that itself: it
/// hands the one command that does the work to the standard macOS
/// administrator prompt, and the command it runs is the same `macid install`
/// every other install path uses.
enum SystemInstaller {

    enum Outcome {
        case done
        case cancelled
        case failed(String)
    }

    /// The command-line tool and PAM module ship inside the app bundle.
    private static var helpers: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
    }

    static var isBundled: Bool {
        FileManager.default.isExecutableFile(atPath: helpers.appendingPathComponent("macid").path)
    }

    static func install() async -> Outcome {
        guard isBundled else {
            return .failed("Run MacID from MacID.app — the helpers it installs are part of the app bundle.")
        }
        let macid = helpers.appendingPathComponent("macid").path
        let module = helpers.appendingPathComponent("pam_macid.so").path
        let script = """
        set -e
        install -d -o root -g wheel -m 755 /opt/macid /opt/macid/lib
        install -o root -g wheel -m 644 \(quoted(module)) /opt/macid/lib/pam_macid.so
        mkdir -p /usr/local/bin
        install -o root -g wheel -m 755 \(quoted(macid)) /usr/local/bin/macid
        /usr/local/bin/macid install --user \(quoted(NSUserName())) --agent app
        """
        return await runAsAdministrator(script)
    }

    static func uninstall() async -> Outcome {
        guard isBundled else {
            return .failed("Run MacID from MacID.app to turn face unlock off.")
        }
        let macid = helpers.appendingPathComponent("macid").path
        return await runAsAdministrator("\(quoted(macid)) uninstall --user \(quoted(NSUserName()))")
    }

    private static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// osascript in a child process rather than NSAppleScript in this one: the
    /// administrator prompt can stay up as long as the user likes, and the
    /// window should keep animating behind it.
    private static func runAsAdministrator(_ shell: String) async -> Outcome {
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", source]
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
                    continuation.resume(returning: .failed(cleaned(message)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: .failed(error.localizedDescription))
            }
        }
    }

    /// osascript prefixes errors with a script offset ("0:165: execution error:").
    private static func cleaned(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = trimmed.range(of: "execution error: ") {
            return String(trimmed[range.upperBound...])
        }
        return trimmed.isEmpty ? "The installer exited with an error." : trimmed
    }
}
