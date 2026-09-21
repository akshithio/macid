import Foundation
import MacIDCore

/// Wires MacID into the lock screen PAM stack and removes it again.
enum Install {

    static let stack = LockScreen.stack
    static let backup = "/etc/pam.d/screensaver_new.macid-backup"
    static let moduleDir = LockScreen.moduleDir
    static let module = LockScreen.module
    static let marker = "# MacID"

    struct Context {
        let userName: String
        let uid: uid_t
        let home: String
    }

    static func install() {
        _ = requireRootWithUser()

        guard FileManager.default.fileExists(atPath: module) else {
            fail("""
            \(module) is missing.
            Reinstall MacID, or run `sudo make install` from the repo.
            """)
        }

        if let problem = LockScreen.rootOnlyChainProblem(module) {
            fail("""
            refusing to wire the lock screen: \(problem)
            The PAM module is loaded by loginwindow as root, so every directory
            above it must be owned by root and not writable by anyone else.
            """)
        }

        print("== pam stack ==")
        wirePAM()
        sweepLegacyLines()

        print("""

        The lock screen is wired. MacID.app takes it from here.
        """)
    }

    static func uninstall() {
        let ctx = requireRootWithUser()

        if isPristine(backup) {
            try? FileManager.default.removeItem(atPath: stack)
            try? FileManager.default.copyItem(atPath: backup, toPath: stack)
            print("restored \(stack) from backup")
        } else {
            if FileManager.default.fileExists(atPath: backup) {
                print("ignoring \(backup): it names a module we install, so it is not pristine")
            }
            stripMacIDLines()
        }
        setOwnerRootWheel(stack, mode: 0o644)
        sweepLegacyLines()

        removeModuleIfUnreferenced(module)

        print("""
        MacID removed. Your enrolled face data is still at:
          \(ctx.home)/Library/Application Support/MacID
        Delete it with:
          rm -rf "\(ctx.home)/Library/Application Support/MacID"
        """)
    }

    /// Runs `uninstall`, then removes /opt/macid and the app bundle.
    static func purge() {
        uninstall()

        print("== files ==")
        if isReferenced(module) {
            print("  kept /opt/macid: a stack in /etc/pam.d still names the module")
        } else if FileManager.default.fileExists(atPath: "/opt/macid") {
            try? FileManager.default.removeItem(atPath: "/opt/macid")
            print("  removed /opt/macid")
        }

        if let app = argument(after: "--app"), FileManager.default.fileExists(atPath: app) {
            try? FileManager.default.removeItem(atPath: app)
            print("  removed \(app)")
        }
    }

    /// True for an auth line naming any MacID module.
    private static func isOurs(_ line: String) -> Bool {
        let ours = ["pam_macid.so", "pam_macidprobe", "pam_face.so", "pam_faceprobe"]
        return ours.contains { line.contains($0) }
    }

    /// True if the stack at `path` names none of our modules.
    private static func isPristine(_ path: String) -> Bool {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return !contents.split(separator: "\n").map(String.init).contains(where: isOurs)
    }


    /// Inserts a `sufficient` MacID line as the stack's first auth line.
    private static func wirePAM() {
        guard var contents = try? String(contentsOfFile: stack, encoding: .utf8) else {
            fail("cannot read \(stack)")
        }

        if !FileManager.default.fileExists(atPath: backup) {
            try? contents.write(toFile: backup, atomically: true, encoding: .utf8)
            setOwnerRootWheel(backup, mode: 0o644)
            print("  backed up -> \(backup)")
        }

        var lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !isOurs($0) }

        let entry = "auth       sufficient     \(module) \(marker)"
        if let firstAuth = lines.firstIndex(where: { $0.hasPrefix("auth") }) {
            lines.insert(entry, at: firstAuth)
        } else {
            lines.append(entry)
        }

        contents = lines.joined(separator: "\n")
        do {
            try contents.write(toFile: stack, atomically: true, encoding: .utf8)
        } catch {
            fail("cannot write \(stack): \(error)")
        }
        setOwnerRootWheel(stack, mode: 0o644)
        print("  \(stack): \(entry.trimmingCharacters(in: .whitespaces))")
    }

    private static func stripMacIDLines() {
        guard let contents = try? String(contentsOfFile: stack, encoding: .utf8) else { return }
        let cleaned = contents.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !isOurs($0) }
            .joined(separator: "\n")
        try? cleaned.write(toFile: stack, atomically: true, encoding: .utf8)
        print("stripped MacID lines from \(stack)")
    }

    /// Stacks that may hold leftover probe lines.
    private static let probedStacks = [
        "sudo", "sudo_local", "screensaver", "screensaver_la", "authorization",
    ]

    /// Removes MacID lines from other stacks, preferring a pristine backup over filtering.
    private static func sweepLegacyLines() {
        for svc in probedStacks {
            let path = "/etc/pam.d/\(svc)"
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }

            let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard lines.contains(where: isOurs) else { continue }

            let backups = ["\(path).macid-backup", "\(path).faceid-backup"]
            if let pristine = backups.first(where: isPristine) {
                if restore(pristine, to: path) {
                    print("  \(path): restored from \((pristine as NSString).lastPathComponent)")
                    continue
                }
            }

            let mode = currentMode(path) ?? 0o644
            let cleaned = lines.filter { !isOurs($0) }.joined(separator: "\n")
            do {
                try cleaned.write(toFile: path, atomically: true, encoding: .utf8)
                setOwnerRootWheel(path, mode: mode)
                print("  \(path): stripped legacy lines")
            } catch {
                print("  warning: could not clean \(path): \(error)")
            }
        }
    }


    /// True if any live file in /etc/pam.d names this module; errs toward true.
    private static func isReferenced(_ modulePath: String) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/etc/pam.d") else {
            return true
        }
        for entry in entries where !entry.hasSuffix("-backup") {
            guard let contents = try? String(contentsOfFile: "/etc/pam.d/\(entry)", encoding: .utf8) else {
                return true
            }
            if contents.contains(modulePath) { return true }
        }
        return false
    }

    private static func removeModuleIfUnreferenced(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        if isReferenced(path) {
            print("  kept \(path): still named by a stack in /etc/pam.d")
            return
        }
        try? FileManager.default.removeItem(atPath: path)
        print("  removed \(path)")
    }

    private static func restore(_ source: String, to destination: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: source) else { return false }
        let mode = currentMode(source) ?? 0o644
        do {
            try data.write(to: URL(fileURLWithPath: destination), options: .atomic)
            setOwnerRootWheel(destination, mode: mode)
            return true
        } catch {
            return false
        }
    }

    private static func currentMode(_ path: String) -> mode_t? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let perms = attrs[.posixPermissions] as? NSNumber else { return nil }
        return mode_t(perms.uint16Value)
    }

    private static func argument(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Requires root and resolves the user from `--user` (console user only) or SUDO_USER.
    private static func requireRootWithUser() -> Context {
        guard geteuid() == 0 else {
            fail("this needs root — MacID.app runs it through the administrator prompt.")
        }

        let name: String
        if let explicit = argument(after: "--user") {
            guard explicit == consoleUser() else {
                fail("--user \(explicit) is not the user logged in at the console")
            }
            name = explicit
        } else if let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"], !sudoUser.isEmpty {
            name = sudoUser
        } else {
            fail("could not determine the user — run via sudo, or pass --user")
        }

        guard let pw = getpwnam(name) else {
            fail("unknown user \(name)")
        }
        return Context(userName: name,
                       uid: pw.pointee.pw_uid,
                       home: String(cString: pw.pointee.pw_dir))
    }

    private static func consoleUser() -> String? {
        var st = stat()
        guard stat("/dev/console", &st) == 0, let pw = getpwuid(st.st_uid) else { return nil }
        return String(cString: pw.pointee.pw_name)
    }

    private static func setOwnerRootWheel(_ path: String, mode: mode_t) {
        chown(path, 0, 0)
        chmod(path, mode)
    }
}
