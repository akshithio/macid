import Foundation

/// The sequence of head positions enrollment asks for, and whether the head is
/// actually in one.
///
/// The point of enrolling from several angles is that the lock screen will not
/// see you perfectly square-on. That only works if the samples really are from
/// different angles — an earlier version printed "turn your head left" and then
/// captured whatever was in front of the camera 900ms later, so eight samples
/// of someone sitting still all went in as though they covered a range. The
/// calibrated threshold is derived from the spread of those samples, so fake
/// variety produces a threshold that means nothing.
///
/// Nothing here trusts Vision's sign convention. A step that wants the head
/// turned away asks only for enough magnitude; the step after it asks for the
/// same magnitude with the opposite sign. That gets both sides without anyone
/// having to agree on which one is "left".
public enum EnrollmentPlan {

    public enum Axis: Sendable {
        case yaw
        case pitch
    }

    public enum Target: Sendable {
        /// Facing the camera: both angles near zero.
        case centered
        /// Turned far enough along an axis, in either direction.
        case away(Axis)
        /// Turned as far along an axis, the other way from the previous step.
        case opposite(Axis)
    }

    public struct Step: Sendable {
        public let target: Target
        public let prompt: String
        /// Shown under the prompt while the head is not yet where it should be.
        public let hint: String
    }

    /// Vision does not report a continuous angle. Yaw and pitch arrive
    /// quantized into buckets roughly 11.25 degrees apart, topping out around
    /// 45, so these bounds are chosen to fall cleanly between buckets rather
    /// than to mean anything in real degrees. An earlier cap of 42 sat *below*
    /// the top bucket, so turning far enough always reported "too far".
    ///
    /// One bucket off centre still counts as centred; two or more counts as
    /// turned.
    /// Per axis, because a neck is not symmetric and a webcam is not at eye
    /// level. Turning left and right is easy and wants a real turn to be worth
    /// sampling. Chin up and down is a much smaller comfortable range, and the
    /// screen is the thing you have to keep looking at — asking for the same
    /// angle vertically means craning until you can no longer see it.
    public static func awayDegrees(for axis: Axis) -> Double {
        switch axis {
        case .yaw: return 17
        case .pitch: return 9
        }
    }
    /// How near to square-on counts as centered.
    public static let centerDegrees: Double = 13
    /// Once a position is reached it is judged more leniently, so a single
    /// bucket of wobble does not drop you out of it. Without this the prompt
    /// flickers between "hold it" and "keep going" while you are in fact
    /// holding perfectly still — pitch in particular sits right on a bucket
    /// boundary and jitters across it.
    public static let slack: Double = 6
    // There is deliberately no upper bound. A head has a limited range of
    // motion and turning it as far as it goes is exactly what the step asks
    // for; telling someone they have turned "too far" is both unactionable and
    // untrue. A face too oblique to describe fails detection outright, which
    // is reported as not seeing a face at all.

    public static let steps: [Step] = [
        Step(target: .centered,
             prompt: "Look straight at the camera",
             hint: "Square your face to the screen"),
        Step(target: .away(.yaw),
             prompt: "Turn your head to the left",
             hint: "Keep turning until it registers"),
        Step(target: .opposite(.yaw),
             prompt: "Now turn to the right",
             hint: "All the way past centre"),
        Step(target: .away(.pitch),
             prompt: "Lift your chin up",
             hint: "Keep your eyes on the screen"),
        Step(target: .opposite(.pitch),
             prompt: "Now tuck your chin down",
             hint: "Keep your eyes on the screen"),
        Step(target: .centered,
             prompt: "Look straight ahead again",
             hint: "Square your face to the screen"),
    ]

    /// What to tell the user about where their head is right now.
    public enum Verdict: Equatable, Sendable {
        /// In position. Hold it.
        case good
        /// Right idea, not there yet.
        case notFarEnough
        /// Moved the same way as last time, when the other way was asked for.
        case wrongDirection
        /// Vision did not report this angle, so the step cannot be judged.
        case unmeasurable
    }

    /// Judge a pose against a step.
    ///
    /// `previousSign` is the direction taken by the preceding `away` step on
    /// the same axis, which an `opposite` step must reverse.
    /// `holding` widens the window, so reaching a position is harder than
    /// keeping it. See `slack`.
    /// `baseline` is how the head sits at rest, measured at the first centred
    /// step. Everything after is judged as movement away from that rather than
    /// from an absolute zero, because a laptop camera looks up at you: resting
    /// pitch is already well off zero before anyone has moved.
    public static func judge(_ pose: FaceEngine.Pose,
                             against target: Target,
                             previousSign: Double?,
                             holding: Bool = false,
                             baseline: FaceEngine.Pose? = nil) -> Verdict {
        let give = holding ? slack : 0

        switch target {
        case .centered:
            // Yaw is always reported; pitch may not be, so an absent pitch
            // must not block the step. Judged absolutely: this step is what
            // establishes the baseline, so it cannot lean on one.
            guard let yaw = pose.yaw else { return .unmeasurable }
            if abs(yaw) > centerDegrees + give { return .notFarEnough }
            return .good

        case .away(let axis):
            guard let angle = offset(of: axis, in: pose, from: baseline) else { return .unmeasurable }
            return abs(angle) >= awayDegrees(for: axis) - give ? .good : .notFarEnough

        case .opposite(let axis):
            guard let angle = offset(of: axis, in: pose, from: baseline) else { return .unmeasurable }
            guard abs(angle) >= awayDegrees(for: axis) - give else { return .notFarEnough }
            // With no previous sign to reverse, any far-enough turn will do.
            guard let previousSign else { return .good }
            return angle.sign == previousSign.sign ? .wrongDirection : .good
        }
    }

    /// Median of the recent poses, per axis.
    ///
    /// Vision's angles are quantized and rattle between neighbouring buckets
    /// from frame to frame. Judging a single frame therefore produces a prompt
    /// that flickers; judging the median of the last few does not.
    public static func smoothed(_ poses: [FaceEngine.Pose]) -> FaceEngine.Pose {
        func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        return FaceEngine.Pose(
            yaw: median(poses.compactMap(\.yaw)),
            pitch: median(poses.compactMap(\.pitch)),
            roll: median(poses.compactMap(\.roll)))
    }

    /// The angle relative to how the head rests, when that is known.
    public static func offset(of axis: Axis,
                              in pose: FaceEngine.Pose,
                              from baseline: FaceEngine.Pose?) -> Double? {
        guard let angle = value(of: axis, in: pose) else { return nil }
        guard let baseline, let rest = value(of: axis, in: baseline) else { return angle }
        return angle - rest
    }

    public static func value(of axis: Axis, in pose: FaceEngine.Pose) -> Double? {
        switch axis {
        case .yaw: return pose.yaw
        case .pitch: return pose.pitch
        }
    }

    public static func axis(of target: Target) -> Axis? {
        switch target {
        case .centered: return nil
        case .away(let a), .opposite(let a): return a
        }
    }
}
