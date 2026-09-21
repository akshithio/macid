import Foundation

/// Turns captured samples into a saved enrollment and derives the match threshold.
/// Only within-pose distances set the threshold; cross-pose distances are reported as coverage.
public enum Calibration {

    public struct Sample {
        public let descriptor: FaceEngine.Descriptor
        public let eyeAspectRatio: Double

        public init(_ detection: FaceEngine.Detection) throws {
            guard let descriptor = detection.descriptor else {
                throw FaceEngine.EngineError.embeddingFailed
            }
            self.descriptor = descriptor
            self.eyeAspectRatio = detection.eyeAspectRatio
        }
    }

    public struct Result {
        public let samples: Int
        public let noiseWorst: Float
        public let noiseMean: Float
        public let coverageWorst: Float
        public let threshold: Float
        public let openEyeAspectRatio: Double
        public let estimated: Bool
    }

    public enum CalibrationError: Error, CustomStringConvertible {
        case tooFewSamples(Int)
        public var description: String {
            switch self {
            case .tooFewSamples(let n):
                return "only captured \(n) samples, need at least \(Calibration.minimumSamples)"
            }
        }
    }

    public static let minimumSamples = 3

    private static let floor: Float = 0.45
    private static let ceiling: Float = 0.65

    @discardableResult
    public static func commit(poses: [[Sample]], name: String = "Me") throws -> Result {
        let all = poses.flatMap { $0 }
        guard all.count >= minimumSamples else {
            throw CalibrationError.tooFewSamples(all.count)
        }

        let noise = distances(withinEach: poses)
        let coverage = distances(across: poses)

        var config = Config.load()
        config.applySensitivity()
        let threshold = config.threshold
        let estimated = noise.isEmpty

        let ears = all.map(\.eyeAspectRatio).filter { $0 > 0 }.sorted()
        let openEye = ears.isEmpty ? 0 : ears[ears.count / 2]

        config.openEyeAspectRatio = openEye

        try Enrollment.add(name: name, samples: all.map(\.descriptor))
        try config.save()

        return Result(samples: all.count,
                      noiseWorst: noise.max() ?? 0,
                      noiseMean: noise.isEmpty ? 0 : noise.reduce(0, +) / Float(noise.count),
                      coverageWorst: coverage.max() ?? 0,
                      threshold: threshold,
                      openEyeAspectRatio: openEye,
                      estimated: estimated)
    }

    @discardableResult
    public static func commit(_ samples: [Sample], name: String = "Me") throws -> Result {
        try commit(poses: samples.map { [$0] }, name: name)
    }

    private static func distances(withinEach poses: [[Sample]]) -> [Float] {
        var out: [Float] = []
        for group in poses where group.count > 1 {
            for i in 0..<group.count {
                for j in (i + 1)..<group.count {
                    if let d = FaceEngine.distance(from: group[i].descriptor,
                                                   to: [group[j].descriptor]) {
                        out.append(d)
                    }
                }
            }
        }
        return out
    }

    private static func distances(across poses: [[Sample]]) -> [Float] {
        var out: [Float] = []
        for i in 0..<poses.count {
            for j in (i + 1)..<poses.count {
                for a in poses[i] {
                    for b in poses[j] {
                        if let d = FaceEngine.distance(from: a.descriptor, to: [b.descriptor]) {
                            out.append(d)
                        }
                    }
                }
            }
        }
        return out
    }
}
