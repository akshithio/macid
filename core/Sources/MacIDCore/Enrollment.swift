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
    /// Featureprint distance below which a face counts as a match. Lower is
    /// stricter. Calibrated by `macid enroll`, which reports the spread of your
    /// own samples so this is not a number pulled out of the air.
    public var threshold: Float = 0.55

    /// How many consecutive matching frames are required before we vouch.
    public var requiredFrames: Int = 3

    /// Require a blink before vouching. This is what stops a photo.
    public var requireBlink: Bool = true

    /// Seconds to keep trying after the screen locks before giving up and
    /// releasing the camera.
    public var scanTimeout: TimeInterval = 60

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
}

public enum Enrollment {

    public enum EnrollError: Error, CustomStringConvertible {
        case nothingEnrolled
        case corrupt(String)

        public var description: String {
            switch self {
            case .nothingEnrolled:
                return "no enrolled face. Run: macid enroll"
            case .corrupt(let why):
                return "enrolled data unreadable (\(why)). Re-run: macid enroll"
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
