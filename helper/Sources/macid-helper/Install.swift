import Foundation
import MacIDCore

/// Wires MacID into the system, and takes it back out again.
///
/// This lives in the binary rather than in a shell script so that the curl
/// installer, `make install` and the menu bar app all drive exactly the same
/// code path. A second implementation in bash is a second thing to get wrong.
enum Install {

    static let stack = LockScreen.stack
    static let backup = "/etc/pam.d/screensaver_new.macid-backup"
    static let moduleDir = LockScreen.moduleDir
    static let module = LockScreen.module
    static let label = "io.akshith.macid"
    static let marker = "# MacID"

    struct Context {
        let userName: String
        let uid: uid_t
        let home: String
        var plistPath: String { "\(home)/Library/LaunchAgents/\(label).plist" }
    }

    // MARK: - Entry points

    static func install() {
        let ctx = requireRootWithUser()

        guard FileManager.default.fileExists(atPath: module) else {
            fail("""
            \(module) is missing.
            Run `make install` from the repo, or reinstall with:
              curl -fsSL https://macid.akshith.io/install.sh | bash
            """)
        }

        if let problem = LockScreen.rootOnlyChainProblem(module) {
            fail("""
            refusing to wire the lock screen: \(problem)
            The PAM module is loaded by loginwindow as root, so every directory
            above it must be owned by root and not writable by anyone else.
            """)
        }

        // MacID.app hosts the agent: it is the process that holds the camera
        // grant and starts at login. Older builds ran `macid run` under
        // launchd; tear that down so the two cannot race for the socket.
        print("== agent ==")
        shell("/bin/launchctl", ["bootout", "gui/\(ctx.uid)/\(label)"], asUser: ctx)
        if FileManager.default.fileExists(atPath: ctx.plistPath) {
            try? FileManager.default.removeItem(atPath: ctx.plistPath)
            print("  removed the launchd agent; MacID.app runs it now")
        } else {
            print("  run by MacID.app")
        }

        print("== pam stack ==")
        wirePAM()
        // Order matters: every stack has to stop naming a legacy module before
        // that module's file can be deleted. See removeLegacyArtifacts().
        sweepLegacyLines()
        removeLegacyArtifacts()

        print("""

        The lock screen is wired. MacID.app takes it from here.
        """)
    }

    static func uninstall() {
        let ctx = requireRootWithUser()

        // A backup is only worth restoring if it is itself clean. An early
        // build captured this one *after* the probe had already edited the
        // stack, so it names a module that no longer exists — and OpenPAM
        // refuses to initialize a stack at all when a listed module is
        // missing, which would leave the lock screen unable to authenticate
        // anyone. When the backup is not pristine, filter instead.
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

        shell("/bin/launchctl", ["bootout", "gui/\(ctx.uid)/\(label)"], asUser: ctx)
        try? FileManager.default.removeItem(atPath: ctx.plistPath)
        removeModuleIfUnreferenced(module)
        removeLegacyArtifacts()

        print("""
        MacID removed. Your enrolled face data is still at:
          \(ctx.home)/Library/Application Support/MacID
        Delete it with:
          rm -rf "\(ctx.home)/Library/Application Support/MacID"
        """)
    }

    // MARK: - PAM

    /// True for any auth line this project has ever written, under any of the
    /// names it has shipped under. Install and uninstall both clean on this, so
    /// upgrading from an older build cannot strand a `sufficient` line.
    private static func isOurs(_ line: String) -> Bool {
        let ours = ["pam_macid.so", "pam_macidprobe", "pam_face.so", "pam_faceprobe"]
        return ours.contains { line.contains($0) }
    }

    /// A saved stack is trustworthy only if it names none of our modules.
    /// Restoring one that does would reintroduce the very line uninstall is
    /// supposed to remove — pointing at a path we are about to delete.
    private static func isPristine(_ path: String) -> Bool {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return !contents.split(separator: "\n").map(String.init).contains(where: isOurs)
    }


    /// Inserted as the FIRST auth line and marked `sufficient`: if the agent
    /// vouches, the stack short-circuits; if it does not, the module returns
    /// PAM_IGNORE and the untouched password stack below runs as normal.
    private static func wirePAM() {
        guard var contents = try? String(contentsOfFile: stack, encoding: .utf8) else {
            fail("cannot read \(stack)")
        }

        if !FileManager.default.fileExists(atPath: backup) {
            try? contents.write(toFile: backup, atomically: true, encoding: .utf8)
            setOwnerRootWheel(backup, mode: 0o644)
            print("  backed up -> \(backup)")
        }

        // Drop any previous MacID or probe lines so repeat installs stay clean.
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

    /// Every stack the diagnostic probe has ever been wired into.
    private static let probedStacks = [
        "sudo", "screensaver", "screensaver_la", "authorization",
    ]

    /// Strip MacID and probe lines from every stack other than the one MacID
    /// deliberately lives in.
    ///
    /// Prefers restoring a pristine backup over filtering: a backup is exactly
    /// what Apple shipped, including file mode (sudo ships 0444, not 0644), and
    /// a filter can only remove what it knows to look for. A backup is only
    /// trusted if it is itself free of our lines.
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


    /// True if any live file in /etc/pam.d names this module.
    ///
    /// Fails toward "referenced". OpenPAM refuses to initialize a stack at all
    /// when a listed module is missing — even an `optional` one — so deleting a
    /// module that is still named breaks every consumer of that stack,
    /// including sudo. Leaving an unreferenced file on disk costs nothing. When
    /// in doubt, keep the file.
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

    /// Probe modules and trigger files left behind by earlier builds.
    private static func removeLegacyArtifacts() {
        for stale in ["/usr/local/lib/pam/pam_macid.so",
                      "/usr/local/lib/pam/pam_macidprobe.so",
                      "/usr/local/lib/pam/pam_faceprobe.so",
                      "/usr/local/lib/pam/pam_face.so",
                      "\(moduleDir)/pam_macidprobe.so"] {
            removeModuleIfUnreferenced(stale)
        }
        // The old command-line tool. MacID.app carries its own helper in
        // Contents/Helpers, so nothing should be on PATH any more; an
        // out-of-date copy there would only be a second thing to keep in sync.
        for stale in ["/usr/local/bin/macid"] {
            if FileManager.default.fileExists(atPath: stale) {
                try? FileManager.default.removeItem(atPath: stale)
                print("  removed \(stale) (the command-line tool is gone)")
            }
        }

        // Trigger files are not referenced by any stack; they are always safe
        // to remove, and a lingering one is the dangerous direction.
        for trigger in ["/var/db/macid-approve", "/var/db/faceid-approve"] {
            if FileManager.default.fileExists(atPath: trigger) {
                try? FileManager.default.removeItem(atPath: trigger)
                print("  removed \(trigger)")
            }
        }
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

    // MARK: - launchd

    // MARK: - helpers


    private static func argument(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// The user whose lock screen this is. Under sudo that is SUDO_USER. The
    /// app installs through the system administrator prompt, which runs the
    /// command as root with no SUDO_USER, so it passes `--user` instead —
    /// accepted only when it names the console user, so a root shell cannot be
    /// talked into installing for an arbitrary account.
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

    private static func gidOf(_ user: String) -> gid_t {
        guard let pw = getpwnam(user) else { return 20 }
        return pw.pointee.pw_gid
    }

    private static func setOwnerRootWheel(_ path: String, mode: mode_t) {
        chown(path, 0, 0)
        chmod(path, mode)
    }

    @discardableResult
    private static func shell(_ path: String, _ args: [String], asUser ctx: Context) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-u", ctx.userName, path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
