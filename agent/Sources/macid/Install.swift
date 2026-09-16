import Foundation

/// Wires MacID into the system, and takes it back out again.
///
/// This lives in the binary rather than in a shell script so that the curl
/// installer, `make install` and the menu bar app all drive exactly the same
/// code path. A second implementation in bash is a second thing to get wrong.
enum Install {

    static let stack = "/etc/pam.d/screensaver_new"
    static let backup = "/etc/pam.d/screensaver_new.macid-backup"
    /// Every directory from here up to / must be owned by root and writable by
    /// nobody else. loginwindow loads this file as root; if any component of
    /// its path is writable by a user, that user can swap the directory out
    /// and put their own code into the lock screen. /usr/local/lib fails this
    /// on any Mac with Homebrew, which is why MacID does not live there.
    static let moduleDir = "/opt/macid/lib"
    static let module = "/opt/macid/lib/pam_macid.so"
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

        if let problem = rootOnlyChainProblem(module) {
            fail("""
            refusing to wire the lock screen: \(problem)
            The PAM module is loaded by loginwindow as root, so every directory
            above it must be owned by root and not writable by anyone else.
            """)
        }

        print("== launch agent ==")
        writeLaunchAgent(ctx)
        bootstrapAgent(ctx)

        print("== pam stack ==")
        wirePAM()
        // Order matters: every stack has to stop naming a legacy module before
        // that module's file can be deleted. See removeLegacyArtifacts().
        sweepLegacyLines()
        removeLegacyArtifacts()

        print("""

        MacID is installed.

          1. Enroll your face:   macid enroll
          2. Check it works:     macid test
          3. Lock the screen and press Return on the empty password field.

        Remove it all with:      sudo macid uninstall
        """)
    }

    static func uninstall() {
        let ctx = requireRootWithUser()

        if FileManager.default.fileExists(atPath: backup) {
            try? FileManager.default.removeItem(atPath: stack)
            try? FileManager.default.copyItem(atPath: backup, toPath: stack)
            print("restored \(stack) from backup")
        } else {
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
            if let pristine = backups.first(where: { candidate in
                guard let b = try? String(contentsOfFile: candidate, encoding: .utf8) else { return false }
                return !b.split(separator: "\n").map(String.init).contains(where: isOurs)
            }) {
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


    /// nil if `path` and every directory above it is owned by root, not a
    /// symlink, and not group- or world-writable; otherwise a description of
    /// the first component that is not.
    static func rootOnlyChainProblem(_ path: String) -> String? {
        var current = path
        while true {
            var st = stat()
            guard lstat(current, &st) == 0 else {
                return "\(current) does not exist"
            }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                return "\(current) is a symlink"
            }
            if st.st_uid != 0 {
                let owner = getpwuid(st.st_uid).map { String(cString: $0.pointee.pw_name) } ?? "uid \(st.st_uid)"
                return "\(current) is owned by \(owner), not root"
            }
            if st.st_mode & (S_IWGRP | S_IWOTH) != 0 {
                return "\(current) is writable by group or others (mode \(String(st.st_mode & 0o7777, radix: 8)))"
            }
            if current == "/" { return nil }
            current = (current as NSString).deletingLastPathComponent
            if current.isEmpty { current = "/" }
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

    /// A LaunchAgent, not a LaunchDaemon: it has to live in the user's GUI
    /// session both to receive com.apple.screenIsLocked and because the camera
    /// TCC grant belongs to the user, not to root.
    private static func writeLaunchAgent(_ ctx: Context) {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>Label</key>
        \t<string>\(label)</string>
        \t<key>ProgramArguments</key>
        \t<array>
        \t\t<string>/usr/local/bin/macid</string>
        \t\t<string>run</string>
        \t</array>
        \t<key>RunAtLoad</key>
        \t<true/>
        \t<key>KeepAlive</key>
        \t<true/>
        \t<key>ProcessType</key>
        \t<string>Background</string>
        \t<key>StandardOutPath</key>
        \t<string>/tmp/macid.out.log</string>
        \t<key>StandardErrorPath</key>
        \t<string>/tmp/macid.err.log</string>
        </dict>
        </plist>
        """

        let dir = "\(ctx.home)/Library/LaunchAgents"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        do {
            try plist.write(toFile: ctx.plistPath, atomically: true, encoding: .utf8)
        } catch {
            fail("cannot write \(ctx.plistPath): \(error)")
        }
        chown(ctx.plistPath, ctx.uid, gidOf(ctx.userName))
        chmod(ctx.plistPath, 0o644)
        chown(dir, ctx.uid, gidOf(ctx.userName))
        print("  \(ctx.plistPath)")
    }

    private static func bootstrapAgent(_ ctx: Context) {
        shell("/bin/launchctl", ["bootout", "gui/\(ctx.uid)/\(label)"], asUser: ctx)
        let rc = shell("/bin/launchctl",
                       ["bootstrap", "gui/\(ctx.uid)", ctx.plistPath], asUser: ctx)
        if rc == 0 {
            print("  loaded as gui/\(ctx.uid)/\(label)")
        } else {
            print("  warning: launchctl bootstrap exited \(rc) — start it with:")
            print("    launchctl bootstrap gui/\(ctx.uid) \(ctx.plistPath)")
        }
    }

    // MARK: - helpers

    private static func requireRootWithUser() -> Context {
        guard geteuid() == 0 else {
            fail("this needs root. Run: sudo macid \(CommandLine.arguments.dropFirst().first ?? "install")")
        }
        guard let name = ProcessInfo.processInfo.environment["SUDO_USER"], !name.isEmpty else {
            fail("could not determine the invoking user — run via sudo, not as root directly")
        }
        guard let pw = getpwnam(name) else {
            fail("unknown user \(name)")
        }
        return Context(userName: name,
                       uid: pw.pointee.pw_uid,
                       home: String(cString: pw.pointee.pw_dir))
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
