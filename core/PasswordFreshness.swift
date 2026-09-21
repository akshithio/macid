import Foundation

/// Requires the password after a hibernation or 48 hours since the last non-face unlock.
public final class PasswordFreshness {
    public static let maximumAge: TimeInterval = 48 * 3600

    private let lock = NSLock()
    private var hibernations = PasswordFreshness.hibernationCount()
    private var presentedAt = Date()

    public init() {}

    /// Call when the screen unlocks by anything other than a face.
    public func credentialPresented() {
        lock.lock(); defer { lock.unlock() }
        hibernations = Self.hibernationCount()
        presentedAt = Date()
    }

    /// Why the password is needed right now, or nil if a face may unlock.
    public var reasonPasswordRequired: String? {
        lock.lock(); defer { lock.unlock() }
        if Self.hibernationCount() != hibernations {
            return "the Mac has hibernated since the last password"
        }
        if Date().timeIntervalSince(presentedAt) > Self.maximumAge {
            return "48 hours since the last password"
        }
        return nil
    }

    /// Hibernations since boot, from `kern.hibernatecount`.
    static func hibernationCount() -> Int32 {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hibernatecount", &count, &size, nil, 0) == 0 else { return -1 }
        return count
    }
}
