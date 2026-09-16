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

    public static var enrolled: URL { dir.appendingPathComponent("enrolled.archive") }
    public static var config: URL { dir.appendingPathComponent("config.json") }
    public static var socket: URL { dir.appendingPathComponent("agent.sock") }
    public static var log: URL { dir.appendingPathComponent("macid.log") }
}

public struct Config: Codable, Equatable {
    /// Featureprint distance below which a face counts as a match. Lower is
    /// stricter. Calibrated by `faced enroll`, which reports the spread of your
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
                return "no enrolled face. Run: faced enroll"
            case .corrupt(let why):
                return "enrolled data unreadable (\(why)). Re-run: faced enroll"
            }
        }
    }

    public static func save(_ descriptors: [FaceEngine.Descriptor]) throws {
        let prints = descriptors.map { $0.print }
        let data = try NSKeyedArchiver.archivedData(
            withRootObject: prints, requiringSecureCoding: true)
        try data.write(to: Paths.enrolled, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Paths.enrolled.path)
    }

    public static func load() throws -> [FaceEngine.Descriptor] {
        guard FileManager.default.fileExists(atPath: Paths.enrolled.path) else {
            throw EnrollError.nothingEnrolled
        }
        let data = try Data(contentsOf: Paths.enrolled)
        guard let prints = try NSKeyedUnarchiver.unarchivedArrayOfObjects(
            ofClass: VNFeaturePrintObservation.self, from: data) else {
            throw EnrollError.corrupt("unexpected archive contents")
        }
        guard !prints.isEmpty else { throw EnrollError.nothingEnrolled }
        return prints.map { FaceEngine.Descriptor(print: $0) }
    }

    public static var isEnrolled: Bool {
        (try? load())?.isEmpty == false
    }

    public static func clear() throws {
        try? FileManager.default.removeItem(at: Paths.enrolled)
    }
}
