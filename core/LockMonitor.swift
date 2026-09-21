import Foundation
import CoreGraphics

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

    public static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
