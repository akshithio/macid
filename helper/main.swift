import Foundation
import MacIDCore

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
case "purge":
    Install.purge()
default:
    fail("""
    internal helper — run MacID.app instead.

      macid-helper install     wire the lock screen (root)
      macid-helper uninstall   unwire it (root)
      macid-helper purge       unwire it, then remove /opt/macid and the app (root)
    """)
}
