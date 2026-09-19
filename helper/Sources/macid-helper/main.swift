import Foundation
import MacIDCore

/// The privileged half of MacID, and nothing else.
///
/// Changing the lock screen needs root; MacID.app must not run as root. So the
/// work that needs root lives here, in a small binary inside the app bundle
/// that the app hands to the standard administrator prompt. It is not a
/// command-line interface: it has no enrollment, no recognition, no agent. Face
/// unlock is the app, and the app is where every user-facing action lives.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("macid-helper: \(message)\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "install":
    Install.install()
case "uninstall":
    Install.uninstall()
default:
    fail("""
    internal helper — run MacID.app instead.

      macid-helper install     wire the lock screen (root)
      macid-helper uninstall   unwire it (root)
    """)
}
