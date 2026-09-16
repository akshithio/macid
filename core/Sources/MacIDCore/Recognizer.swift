import Foundation
import CoreGraphics

/// Decides whether the person in front of the camera is the enrolled one.
///
/// Two independent gates have to pass. Identity: several consecutive frames
/// must land within the distance threshold. Liveness: the eyes must actually
/// blink. The blink gate is the one that matters against the obvious attack —
/// a photo of you held up to the camera passes identity effortlessly and never
/// passes liveness.
public final class Recognizer {

    public enum Outcome {
        case searching(String)
        case matched(distance: Float, frames: Int)
        case rejected(String)
    }

    private let config: Config
    private let enrolled: [FaceEngine.Descriptor]

    private var consecutiveMatches = 0
    private var bestDistance: Float = .greatestFiniteMagnitude
    private var framesSeen = 0

    // Blink state machine.
    private enum BlinkPhase { case needOpen, needClosed, needReopen, done }
    private var blinkPhase: BlinkPhase
    private var baselineEAR: Double = 0

    public init(config: Config, enrolled: [FaceEngine.Descriptor]) {
        self.config = config
        self.enrolled = enrolled
        self.blinkPhase = config.requireBlink ? .needOpen : .done
    }

    public var hasBlinked: Bool { blinkPhase == .done }

    public func reset() {
        consecutiveMatches = 0
        bestDistance = .greatestFiniteMagnitude
        framesSeen = 0
        baselineEAR = 0
        blinkPhase = config.requireBlink ? .needOpen : .done
    }

    public func consider(_ image: CGImage) -> Outcome {
        framesSeen += 1

        let detection: FaceEngine.Detection
        do {
            detection = try FaceEngine.analyze(image)
        } catch {
            // A frame with no face is the normal case while you are walking up;
            // it breaks the consecutive-match run but is not a rejection.
            consecutiveMatches = 0
            return .searching("\(error)")
        }

        updateBlink(with: detection.eyeAspectRatio)

        guard let descriptor = detection.descriptor,
              let distance = FaceEngine.distance(from: descriptor, to: enrolled) else {
            consecutiveMatches = 0
            return .searching("no comparable descriptor")
        }

        bestDistance = min(bestDistance, distance)

        guard distance <= config.threshold else {
            consecutiveMatches = 0
            return .searching(String(format: "face seen, distance %.3f > %.3f",
                                     distance, config.threshold))
        }

        consecutiveMatches += 1

        guard consecutiveMatches >= config.requiredFrames else {
            return .searching(String(format: "match %d/%d (distance %.3f)",
                                     consecutiveMatches, config.requiredFrames, distance))
        }

        guard hasBlinked else {
            // Identity is satisfied and we are only waiting on liveness. Say so
            // explicitly — "it recognizes me but will not unlock" is otherwise
            // an infuriating thing to debug.
            return .searching(String(format: "recognized (distance %.3f) — blink to confirm",
                                     distance))
        }

        return .matched(distance: bestDistance, frames: framesSeen)
    }

    /// Eye aspect ratio varies a lot between people and with distance from the
    /// camera, so the thresholds are relative to the widest-open eyes we have
    /// seen this session rather than fixed constants.
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
