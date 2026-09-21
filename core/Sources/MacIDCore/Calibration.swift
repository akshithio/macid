import Foundation

/// Turns captured samples into a saved enrollment, and derives the match
/// threshold from them.
///
/// The threshold is the whole security boundary, so where it comes from
/// matters. It has to sit above how much your own face varies between one look
/// and the next, and well below the distance to somebody else's face.
///
/// The subtlety is which variation counts. Enrollment deliberately captures
/// several head angles, because the lock screen will not see you square-on;
/// the distance between your left-profile sample and your right-profile sample
/// is therefore large *by design*. An earlier version pooled every pair of
/// samples and took the worst, so the more honest the enrollment, the looser
/// the threshold it produced — it pinned to the 0.75 ceiling and reported
/// "uneven lighting" on every run. It was measuring coverage and calling it
/// noise.
///
/// So samples arrive grouped by the pose they were held at. Distances *within*
/// a group are genuine noise: same face, same angle, seconds apart, differing
/// only by light, sensor and micro-expression. That is what sets the
/// threshold. Distances *across* groups are coverage, and are reported but
/// never used to loosen the gate.
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
        /// Worst distance between two samples of the *same* held pose. This is
        /// the real noise floor, and what the threshold is built on.
        public let noiseWorst: Float
        public let noiseMean: Float
        /// Worst distance between samples of *different* poses. Large is good:
        /// it means enrollment actually covers a range of angles.
        public let coverageWorst: Float
        public let threshold: Float
        public let openEyeAspectRatio: Double
        /// True when there were no same-pose pairs to measure, so the
        /// threshold had to fall back to a conservative default.
        public let estimated: Bool

        /// Genuinely noisy capture: two photos of the same held pose, taken
        /// seconds apart, came out far apart. Uneven or changing light is the
        /// usual cause — unlike the old check, this cannot be triggered just by
        /// turning your head.
        public var isNoisy: Bool { !estimated && noiseWorst > 0.34 }

        /// Enrollment did not actually cover much of a range, so the lock
        /// screen will only recognize you head-on.
        public var isNarrow: Bool { coverageWorst < 0.15 }
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

    /// Headroom over the measured noise floor. The lock screen sees you in
    /// worse conditions than enrollment did — different light, different time
    /// of day — so the gate sits above the worst same-pose distance rather
    /// than at it.
    private static let headroom: Float = 1.6

    /// Hard bounds. The ceiling is the security-relevant one: past roughly
    /// this distance a featureprint stops distinguishing people reliably, so
    /// no amount of measured noise is allowed to open the gate further. A
    /// threshold that is too tight only costs you a password prompt; one that
    /// is too loose costs you the machine.
    private static let floor: Float = 0.30
    private static let ceiling: Float = 0.55

    /// Calibrate from samples grouped by the pose each was held at, then save.
    ///
    /// Every sample is enrolled, whatever group it came from — coverage is the
    /// reason for capturing angles in the first place. Only the grouping
    /// affects the threshold.
    @discardableResult
    public static func commit(poses: [[Sample]]) throws -> Result {
        let all = poses.flatMap { $0 }
        guard all.count >= minimumSamples else {
            throw CalibrationError.tooFewSamples(all.count)
        }

        let noise = distances(withinEach: poses)
        let coverage = distances(across: poses)

        let threshold: Float
        let estimated: Bool
        if let worst = noise.max() {
            threshold = min(max(worst * headroom, floor), ceiling)
            estimated = false
        } else {
            // Nothing was held long enough to be sampled twice, so there is no
            // noise floor to measure. Take the floor rather than inferring one
            // from cross-pose distances, which would be the old bug again.
            threshold = floor
            estimated = true
        }

        // Median rather than mean: one sample caught mid-blink should not drag
        // the open-eye baseline down.
        let ears = all.map(\.eyeAspectRatio).filter { $0 > 0 }.sorted()
        let openEye = ears.isEmpty ? 0 : ears[ears.count / 2]

        var config = Config.load()
        config.threshold = threshold
        config.openEyeAspectRatio = openEye

        try Enrollment.save(all.map(\.descriptor))
        try config.save()

        return Result(samples: all.count,
                      noiseWorst: noise.max() ?? 0,
                      noiseMean: noise.isEmpty ? 0 : noise.reduce(0, +) / Float(noise.count),
                      coverageWorst: coverage.max() ?? 0,
                      threshold: threshold,
                      openEyeAspectRatio: openEye,
                      estimated: estimated)
    }

    /// Ungrouped samples. Every sample is treated as its own pose, so there
    /// are no same-pose pairs and the threshold falls back to the floor.
    @discardableResult
    public static func commit(_ samples: [Sample]) throws -> Result {
        try commit(poses: samples.map { [$0] })
    }

    /// Pairwise distances inside each group: the same face at the same angle.
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

    /// Distances between samples of different poses — how much ground the
    /// enrollment covers.
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
