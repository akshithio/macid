import Foundation
import CoreGraphics

/// Watches the screen lock.
///
/// These two distributed notifications are what the whole design hangs on: they
/// fire in the user's session and keep being delivered while the screen is
/// locked, which is why the agent can be an ordinary LaunchAgent rather than a
/// root daemon. A root daemon would have a much harder time with the camera,
/// which is gated on a TCC grant that belongs to the logged-in user.
public final class LockMonitor {

    public static let locked = Notification.Name("com.apple.screenIsLocked")
    public static let unlocked = Notification.Name("com.apple.screenIsUnlocked")

    public init() {}

    private var observers: [NSObjectProtocol] = []
    private let center = DistributedNotificationCenter.default()

    public func start(onLock: @escaping () -> Void, onUnlock: @escaping () -> Void) {
        observers.append(center.addObserver(
            forName: Self.locked, object: nil, queue: .main
        ) { _ in onLock() })

        observers.append(center.addObserver(
            forName: Self.unlocked, object: nil, queue: .main
        ) { _ in onUnlock() })
    }

    public func stop() {
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    /// Whether the screen is locked right now, for the case where the agent
    /// starts up while already at the lock screen.
    public static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
