import Foundation
import Darwin

/// Read-only facts about how the lock screen is wired.
public enum LockScreen {

    public static let stack = "/etc/pam.d/screensaver_new"

    /// Must be root-owned and writable by no one else, all the way up to /.
    public static let moduleDir = "/opt/macid/lib"
    public static let module = "/opt/macid/lib/pam_macid.so"

    /// The source hash stamped into a module at build time, if any.
    public static func moduleID(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
              let range = data.range(of: Data("MACID-MODULE-ID:".utf8)) else { return nil }
        let id = data[range.upperBound...].prefix(40)
        return String(data: id, encoding: .ascii)
    }

    public static func moduleIsOutdated(comparedTo bundled: String) -> Bool {
        guard FileManager.default.fileExists(atPath: module),
              let shipped = moduleID(at: bundled) else { return false }
        return moduleID(at: module) != shipped
    }

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

    /// Describes the first component of `path` that is a symlink, not root-owned, or group/world-writable; nil if none.
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

