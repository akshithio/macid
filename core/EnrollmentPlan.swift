import Foundation

/// The head positions enrollment asks for, and whether the head is currently in one.
public enum EnrollmentPlan {

    public enum Axis: Sendable {
        case yaw
        case pitch
    }

    public enum Target: Sendable {
        case centered
        case away(Axis)
        case opposite(Axis)
    }

    public struct Step: Sendable {
        public let target: Target
        public let prompt: String
        public let hint: String
    }

    public static func awayDegrees(for axis: Axis) -> Double {
        switch axis {
        case .yaw: return 17
        case .pitch: return 9
        }
    }
    public static let centerDegrees: Double = 13
    public static let slack: Double = 6

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

    public enum Verdict: Equatable, Sendable {
        case good
        case notFarEnough
        case wrongDirection
        case unmeasurable
    }

    public static func judge(_ pose: FaceEngine.Pose,
                             against target: Target,
                             previousSign: Double?,
                             holding: Bool = false,
                             baseline: FaceEngine.Pose? = nil) -> Verdict {
        let give = holding ? slack : 0

        switch target {
        case .centered:
            guard let yaw = pose.yaw else { return .unmeasurable }
            if abs(yaw) > centerDegrees + give { return .notFarEnough }
            return .good

        case .away(let axis):
            guard let angle = offset(of: axis, in: pose, from: baseline) else { return .unmeasurable }
            return abs(angle) >= awayDegrees(for: axis) - give ? .good : .notFarEnough

        case .opposite(let axis):
            guard let angle = offset(of: axis, in: pose, from: baseline) else { return .unmeasurable }
            guard abs(angle) >= awayDegrees(for: axis) - give else { return .notFarEnough }
            guard let previousSign else { return .good }
            return angle.sign == previousSign.sign ? .wrongDirection : .good
        }
    }

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
