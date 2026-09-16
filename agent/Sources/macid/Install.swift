import Foundation

/// Wires MacID into the system, and takes it back out again.
///
/// This lives in the binary rather than in a shell script so that the curl
/// installer, `make install` and the menu bar app all drive exactly the same
/// code path. A second implementation in bash is a second thing to get wrong.
enum Install {

    static let stack = "/etc/pam.d/screensaver_new"
    static let backup = "/etc/pam.d/screensaver_new.macid-backup"
    static let module = "/usr/local/lib/pam/pam_macid.so"
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

        print("== launch agent ==")
        writeLaunchAgent(ctx)
        bootstrapAgent(ctx)

        print("== pam stack ==")
        wirePAM()

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

        shell("/bin/launchctl", ["bootout", "gui/\(ctx.uid)/\(label)"], asUser: ctx)
        try? FileManager.default.removeItem(atPath: ctx.plistPath)
        try? FileManager.default.removeItem(atPath: module)
        try? FileManager.default.removeItem(atPath: "/usr/local/lib/pam/pam_macidprobe.so")

        print("""
        MacID removed. Your enrolled face data is still at:
          \(ctx.home)/Library/Application Support/MacID
        Delete it with:
          rm -rf "\(ctx.home)/Library/Application Support/MacID"
        """)
    }

    // MARK: - PAM

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
            .filter { !$0.contains("pam_macid.so") && !$0.contains("pam_macidprobe") }

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
            .filter { !$0.contains("pam_macid.so") && !$0.contains("pam_macidprobe") }
            .joined(separator: "\n")
        try? cleaned.write(toFile: stack, atomically: true, encoding: .utf8)
        print("stripped MacID lines from \(stack)")
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
