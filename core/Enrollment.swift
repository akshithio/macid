import Foundation
import Vision

/// Storage locations; the directory is 0700 so no other user can read or replace enrolled descriptors.
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
    public static var legacyEnrolled: URL { dir.appendingPathComponent("enrolled.archive") }
    public static var config: URL { dir.appendingPathComponent("config.json") }
    public static var socket: URL { dir.appendingPathComponent("agent.sock") }
    public static var log: URL { dir.appendingPathComponent("macid.log") }
}

public struct Config: Codable, Equatable {

    public enum Liveness: String, Codable, CaseIterable {
        case attention
        case blink
    }

    public var threshold: Float = 0.55

    public var requiredFrames: Int = 3

    public var liveness: Liveness = .attention

    public var openEyeAspectRatio: Double = 0

    public var scanTimeout: TimeInterval = 15

    public var sensitivity: Double = 0

    public var warmWithDisplay: Bool = true

    public init() {}

    public static let strictest: Float = 0.45
    public static let loosest: Float = 0.70

    /// Distance of the most similar stranger pair in the LFW test set.
    public static let closestStranger: Float = 0.758

    public static let sensitivityStep = 0.01 / Double(loosest - strictest)

    public static let measuredAcceptance: [Double] = [
        70.6, 73.5, 76.4, 78.2, 79.8, 83.3, 85.7, 88.1, 89.4, 91.0,
        91.5, 92.3, 92.8, 94.2, 95.0, 96.3, 96.8, 97.6, 97.6, 97.6,
        97.6, 97.9, 97.9, 98.1, 98.4, 98.4,
    ]

    public static func measuredAcceptance(for sensitivity: Double) -> Double {
        let hundredths = Int((Double(threshold(for: sensitivity)) * 100).rounded()) - 45
        return measuredAcceptance[max(0, min(measuredAcceptance.count - 1, hundredths))]
    }

    public static func threshold(for sensitivity: Double) -> Float {
        let t = Float(max(0, min(1, sensitivity)))
        return strictest + t * (loosest - strictest)
    }

    public mutating func applySensitivity() {
        threshold = Config.threshold(for: sensitivity)
    }

    public static func load() -> Config {
        guard let data = try? Data(contentsOf: Paths.config),
              var cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            var fresh = Config()
            fresh.applySensitivity()
            return fresh
        }
        cfg.applySensitivity()
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
        case warmWithDisplay, sensitivity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        threshold = try c.decodeIfPresent(Float.self, forKey: .threshold) ?? d.threshold
        requiredFrames = try c.decodeIfPresent(Int.self, forKey: .requiredFrames) ?? d.requiredFrames
        liveness = (try? c.decodeIfPresent(Liveness.self, forKey: .liveness)) ?? nil ?? d.liveness
        openEyeAspectRatio = try c.decodeIfPresent(Double.self, forKey: .openEyeAspectRatio) ?? d.openEyeAspectRatio
        scanTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .scanTimeout) ?? d.scanTimeout
        warmWithDisplay = try c.decodeIfPresent(Bool.self, forKey: .warmWithDisplay) ?? d.warmWithDisplay
        sensitivity = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? d.sensitivity
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

    public struct Face: Codable, Identifiable, Equatable {
        public var id: UUID
        public var name: String
        public var samples: [FaceEngine.Descriptor]
        public var addedAt: Date

        public init(id: UUID = UUID(), name: String,
                    samples: [FaceEngine.Descriptor], addedAt: Date = Date()) {
            self.id = id
            self.name = name
            self.samples = samples
            self.addedAt = addedAt
        }
    }

    private struct Stored: Codable {
        var version: Int
        var faces: [Face]
    }

    private static let formatVersion = 2

    private static func write(_ faces: [Face]) throws {
        let data = try JSONEncoder().encode(Stored(version: Self.formatVersion, faces: faces))
        try data.write(to: Paths.enrolled, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: Paths.enrolled.path)
        try? FileManager.default.removeItem(at: Paths.legacyEnrolled)
    }

    public static func faces() -> [Face] {
        guard FileManager.default.fileExists(atPath: Paths.enrolled.path),
              let data = try? Data(contentsOf: Paths.enrolled),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.version == Self.formatVersion else { return [] }
        return stored.faces
    }

    public static func add(name: String, samples: [FaceEngine.Descriptor]) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? "Face \(faces().count + 1)" : trimmed
        var all = faces().filter { $0.name.caseInsensitiveCompare(label) != .orderedSame }
        all.append(Face(name: label, samples: samples))
        try write(all)
    }

    public static func remove(id: UUID) throws {
        try write(faces().filter { $0.id != id })
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
            throw EnrollError.corrupt("enrolled with an older version of MacID")
        }
        guard stored.version == Self.formatVersion else {
            throw EnrollError.corrupt("enrolled with an older version of MacID")
        }
        let all = stored.faces.flatMap(\.samples)
        guard !all.isEmpty else { throw EnrollError.nothingEnrolled }
        return all
    }

    public static var isEnrolled: Bool {
        (try? load())?.isEmpty == false
    }

    public static func clear() throws {
        try? FileManager.default.removeItem(at: Paths.enrolled)
        try? FileManager.default.removeItem(at: Paths.legacyEnrolled)
    }
}
