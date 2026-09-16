import Foundation
import Darwin

/// Read-only facts about how the lock screen is wired. Writing lives in the
/// `macid install` command, which is the only code that runs as root.
public enum LockScreen {

    public static let stack = "/etc/pam.d/screensaver_new"

    /// Every directory from the module up to / must be owned by root and
    /// writable by nobody else. loginwindow loads this file as root; if any
    /// component of its path is writable by a user, that user can swap the
    /// directory out and put their own code into the lock screen.
    /// /usr/local/lib fails this on any Mac with Homebrew.
    public static let moduleDir = "/opt/macid/lib"
    public static let module = "/opt/macid/lib/pam_macid.so"

    /// The module path the lock screen stack names, if any.
    public static var wiredModulePath: String? {
        (try? String(contentsOfFile: stack, encoding: .utf8))?
            .split(separator: "\n")
            .first { $0.contains("pam_macid.so") && !$0.hasPrefix("#") }
            .flatMap { line in
                line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first { $0.hasPrefix("/") }
            }
            .map(String.init)
    }

    /// Wired, pointing at the module that exists, from a root-only location.
    public static var isWired: Bool {
        guard let path = wiredModulePath else { return false }
        return rootOnlyChainProblem(path) == nil
    }

    /// nil if `path` and every directory above it is owned by root, not a
    /// symlink, and not group- or world-writable; otherwise a description of
    /// the first component that is not.
    public static func rootOnlyChainProblem(_ path: String) -> String? {
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
}
