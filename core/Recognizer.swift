import Foundation
import CoreGraphics

/// Decides whether the person in front of the camera is the enrolled one and is paying attention.
public final class Recognizer {

    public enum Outcome {
        case searching(String)
        case matched(distance: Float, frames: Int)
        case rejected(String)
    }

    private let config: Config
    private let enrolled: [FaceEngine.Descriptor]

    private var consecutiveMatches = 0

    public private(set) var consecutiveNonMatches = 0

    public private(set) var consecutiveFarNonMatches = 0

    private static let farMultiple: Float = 1.5
    private var bestDistance: Float = .greatestFiniteMagnitude
    private var framesSeen = 0

    private enum BlinkPhase { case needOpen, needClosed, needReopen, done }
    private var blinkPhase: BlinkPhase
    private var baselineEAR: Double = 0

    public init(config: Config, enrolled: [FaceEngine.Descriptor]) {
        self.config = config
        self.enrolled = enrolled
        self.blinkPhase = config.liveness == .blink ? .needOpen : .done
    }

    public var hasBlinked: Bool { blinkPhase == .done }

    public func reset() {
        consecutiveMatches = 0
        consecutiveNonMatches = 0
        consecutiveFarNonMatches = 0
        bestDistance = .greatestFiniteMagnitude
        framesSeen = 0
        baselineEAR = 0
        blinkPhase = config.liveness == .blink ? .needOpen : .done
    }

    public func consider(_ image: CGImage) -> Outcome {
        framesSeen += 1

        let detection: FaceEngine.Detection
        do {
            detection = try FaceEngine.analyze(image)
        } catch {
            consecutiveMatches = 0
            consecutiveNonMatches = 0
            consecutiveFarNonMatches = 0
            return .searching("\(error)")
        }

        updateBlink(with: detection.eyeAspectRatio)

        guard let descriptor = detection.descriptor,
              let distance = FaceEngine.distance(from: descriptor, to: enrolled) else {
            consecutiveMatches = 0
            consecutiveNonMatches = 0
            consecutiveFarNonMatches = 0
            return .searching("no comparable descriptor")
        }

        guard eyesOpen(detection.eyeAspectRatio) else {
            consecutiveMatches = 0
            consecutiveNonMatches = 0
            consecutiveFarNonMatches = 0
            return .searching("face seen, eyes closed or looking away")
        }

        bestDistance = min(bestDistance, distance)

        guard distance <= config.threshold else {
            consecutiveMatches = 0
            consecutiveNonMatches += 1
            if distance > config.threshold * Self.farMultiple {
                consecutiveFarNonMatches += 1
            } else {
                consecutiveFarNonMatches = 0
            }
            return .searching(String(format: "face seen, distance %.3f > %.3f",
                                     distance, config.threshold))
        }

        consecutiveNonMatches = 0
        consecutiveFarNonMatches = 0
        consecutiveMatches += 1

        guard consecutiveMatches >= config.requiredFrames else {
            return .searching(String(format: "match %d/%d (distance %.3f)",
                                     consecutiveMatches, config.requiredFrames, distance))
        }

        guard hasBlinked else {
            return .searching(String(format: "recognized (distance %.3f) — waiting for a blink",
                                     distance))
        }

        return .matched(distance: bestDistance, frames: framesSeen)
    }

    private func eyesOpen(_ ear: Double) -> Bool {
        let baseline = config.openEyeAspectRatio
        guard baseline > 0 else { return true }
        return ear >= baseline * 0.5
    }

    private func updateBlink(with ear: Double) {
        guard ear > 0 else { return }
        baselineEAR = max(baselineEAR, ear)
        guard baselineEAR > 0 else { return }

        let openThreshold = baselineEAR * 0.80
        let closedThreshold = baselineEAR * 0.60

        switch blinkPhase {
        case .needOpen:
            if ear >= openThreshold { blinkPhase = .needClosed }
        case .needClosed:
            if ear <= closedThreshold { blinkPhase = .needReopen }
        case .needReopen:
            if ear >= openThreshold { blinkPhase = .done }
        case .done:
            break
        }
    }
}
