import Foundation

/// Turns a set of captured samples into a saved enrollment.
///
/// Used by the app's enrollment screen, so there is one
/// definition of how a threshold is derived and the two can never calibrate
/// the same face differently.
public enum Calibration {

    public struct Sample {
        public let descriptor: FaceEngine.Descriptor
        public let eyeAspectRatio: Double

        public init(_ detection: FaceEngine.Detection) throws {
            guard let descriptor = detection.descriptor else {
                throw FaceEngine.EngineError.featureprintFailed
            }
            self.descriptor = descriptor
            self.eyeAspectRatio = detection.eyeAspectRatio
        }
    }

    public struct Result {
        public let samples: Int
        public let meanSpread: Float
        public let worstSpread: Float
        public let threshold: Float
        public let openEyeAspectRatio: Double

        /// Samples this far apart usually mean uneven lighting during capture.
        public var isNoisy: Bool { worstSpread > 0.5 }
    }

    public enum CalibrationError: Error, CustomStringConvertible {
        case tooFewSamples(Int)
        public var description: String {
            switch self {
            case .tooFewSamples(let n):
                return "only captured \(n) samples, need at least \(Calibration.minimumSamples). Even lighting usually fixes this."
            }
        }
    }

    public static let minimumSamples = 3

    /// Calibrate, then save the enrollment and the calibrated config. Other
    /// settings — liveness mode, scan timeout — are left as the user set them.
    @discardableResult
    public static func commit(_ samples: [Sample]) throws -> Result {
        guard samples.count >= minimumSamples else {
            throw CalibrationError.tooFewSamples(samples.count)
        }

        // The spread among your own samples is the only honest basis for a
        // threshold: it has to sit above how much your own face varies, and
        // well below the distance to anyone else.
        var spreads: [Float] = []
        for i in 0..<samples.count {
            for j in (i + 1)..<samples.count {
                if let d = FaceEngine.distance(from: samples[i].descriptor, to: [samples[j].descriptor]) {
                    spreads.append(d)
                }
            }
        }
        let worst = spreads.max() ?? 0.4
        let mean = spreads.isEmpty ? 0 : spreads.reduce(0, +) / Float(spreads.count)
        // Headroom above the worst self-match, clamped so the gate never becomes
        // meaninglessly loose or impossibly tight.
        let threshold = min(max(worst * 1.25, 0.30), 0.75)

        // Median rather than mean: one sample caught mid-blink should not drag
        // the open-eye baseline down.
        let ears = samples.map(\.eyeAspectRatio).filter { $0 > 0 }.sorted()
        let openEye = ears.isEmpty ? 0 : ears[ears.count / 2]

        var config = Config.load()
        config.threshold = threshold
        config.openEyeAspectRatio = openEye

        try Enrollment.save(samples.map(\.descriptor))
        try config.save()

        return Result(samples: samples.count, meanSpread: mean, worstSpread: worst,
                      threshold: threshold, openEyeAspectRatio: openEye)
    }
}
