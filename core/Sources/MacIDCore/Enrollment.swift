import Foundation
import Vision

/// Where everything lives. The directory is 0700: the enrolled descriptors are
/// the thing that unlocks the machine, so no other user gets to read or, more
/// importantly, replace them.
public enum Paths {
    public static let dir: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacID", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        return base
    }()

    public static var enrolled: URL { dir.appendingPathComponent("enrolled.json") }
    /// Pre-0.1 keyed archive of Vision objects. Unreadable; removed on save.
    public static var legacyEnrolled: URL { dir.appendingPathComponent("enrolled.archive") }
    public static var config: URL { dir.appendingPathComponent("config.json") }
    public static var socket: URL { dir.appendingPathComponent("agent.sock") }
    public static var log: URL { dir.appendingPathComponent("macid.log") }
}

public struct Config: Codable, Equatable {

    /// How MacID decides the face in front of it is a live, attentive person.
    public enum Liveness: String, Codable, CaseIterable {
        /// Eyes open and on the screen, like Face ID's attention check. Nothing
        /// for the user to do. A good photo of the enrolled face can pass it.
        case attention
        /// Additionally wait for a natural blink. Stops a still photo, at the
        /// cost of waiting for the next blink — usually a few seconds.
        case blink
    }

    /// Featureprint distance below which a face counts as a match. Lower is
    /// stricter. Calibrated during enrollment from the spread of your own
    /// samples.
    public var threshold: Float = 0.55

    /// Consecutive matching frames required before vouching.
    public var requiredFrames: Int = 3

    public var liveness: Liveness = .attention

    /// Your eye aspect ratio with eyes naturally open, measured at enrollment.
    /// The attention check is relative to this, because a fixed number cannot
    /// be right for every face. 0 means not calibrated, and the check is
    /// skipped rather than guessed.
    public var openEyeAspectRatio: Double = 0

    /// Longest the camera stays on after the display wakes without finding
    /// you. It turns off the moment you are recognized.
    public var scanTimeout: TimeInterval = 15

    public init() {}

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.config),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return cfg
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Paths.config, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Paths.config.path)
    }

    private enum CodingKeys: String, CodingKey {
        case threshold, requiredFrames, liveness, openEyeAspectRatio, scanTimeout
    }

    /// Every key is optional on read. A config written by an older build must
    /// keep its calibrated threshold rather than failing to decode and silently
    /// falling back to defaults. The old `requireBlink` key is deliberately not
    /// read: blink is now opt-in.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        threshold = try c.decodeIfPresent(Float.self, forKey: .threshold) ?? d.threshold
        requiredFrames = try c.decodeIfPresent(Int.self, forKey: .requiredFrames) ?? d.requiredFrames
        liveness = (try? c.decodeIfPresent(Liveness.self, forKey: .liveness)) ?? nil ?? d.liveness
        openEyeAspectRatio = try c.decodeIfPresent(Double.self, forKey: .openEyeAspectRatio) ?? d.openEyeAspectRatio
        scanTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .scanTimeout) ?? d.scanTimeout
    }
}

public enum Enrollment {

    public enum EnrollError: Error, CustomStringConvertible {
        case nothingEnrolled
        case corrupt(String)

        public var description: String {
            switch self {
            case .nothingEnrolled:
                return "no enrolled face. Enroll in MacID."
            case .corrupt(let why):
                return "enrolled data unreadable (\(why)). Re-enroll in MacID."
            }
        }
    }

    private struct Stored: Codable {
        var version: Int
        var samples: [FaceEngine.Descriptor]
    }

    public static func save(_ descriptors: [FaceEngine.Descriptor]) throws {
        let data = try JSONEncoder().encode(Stored(version: 1, samples: descriptors))
        try data.write(to: Paths.enrolled, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Paths.enrolled.path)
        try? FileManager.default.removeItem(at: Paths.legacyEnrolled)
    }

    public static func load() throws -> [FaceEngine.Descriptor] {
        guard FileManager.default.fileExists(atPath: Paths.enrolled.path) else {
            if FileManager.default.fileExists(atPath: Paths.legacyEnrolled.path) {
                throw EnrollError.corrupt("saved in an older format")
            }
            throw EnrollError.nothingEnrolled
        }
        let stored: Stored
        do {
            stored = try JSONDecoder().decode(Stored.self, from: Data(contentsOf: Paths.enrolled))
        } catch {
            throw EnrollError.corrupt("\(error.localizedDescription)")
        }
        guard stored.version == 1 else { throw EnrollError.corrupt("unknown version \(stored.version)") }
        guard !stored.samples.isEmpty else { throw EnrollError.nothingEnrolled }
        return stored.samples
    }

    public static var isEnrolled: Bool {
        (try? load())?.isEmpty == false
    }

    public static func clear() throws {
        try? FileManager.default.removeItem(at: Paths.enrolled)
        try? FileManager.default.removeItem(at: Paths.legacyEnrolled)
    }
}
