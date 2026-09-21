import Foundation
import Vision
import CoreImage
import CoreGraphics

/// Turns a camera frame into a comparable `Descriptor`, and compares descriptors.
public enum FaceEngine {

    public struct Descriptor: Codable, Equatable {
        public let vector: [Float]
        public init(vector: [Float]) { self.vector = vector }
    }

    public struct Pose {
        public let yaw: Double?
        public let pitch: Double?
        public let roll: Double?

        public init(yaw: Double?, pitch: Double?, roll: Double?) {
            self.yaw = yaw
            self.pitch = pitch
            self.roll = roll
        }

        init(landmarks: VNFaceObservation, rectangles: VNFaceObservation) {
            func degrees(_ n: NSNumber?) -> Double? {
                n.map { $0.doubleValue * 180 / .pi }
            }
            self.yaw = degrees(rectangles.yaw) ?? degrees(landmarks.yaw)
            self.pitch = degrees(rectangles.pitch) ?? degrees(landmarks.pitch)
            self.roll = degrees(rectangles.roll) ?? degrees(landmarks.roll)
        }
    }

    public struct Detection {
        public let observation: VNFaceObservation
        public let eyeAspectRatio: Double
        public let descriptor: Descriptor?
        public let pose: Pose
    }

    public enum EngineError: Error, CustomStringConvertible {
        case noFace
        case multipleFaces(Int)
        case cropFailed
        case embeddingFailed

        public var description: String {
            switch self {
            case .noFace: return "no face in frame"
            case .multipleFaces(let n): return "\(n) faces in frame, need exactly one"
            case .cropFailed: return "could not crop face region"
            case .embeddingFailed: return "could not compute a face embedding"
            }
        }
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    public static func analyze(_ image: CGImage, wantDescriptor: Bool = true) throws -> Detection {
        let landmarks = VNDetectFaceLandmarksRequest()
        let rectangles = VNDetectFaceRectanglesRequest()
        if VNDetectFaceRectanglesRequestRevision3 <= VNDetectFaceRectanglesRequest.currentRevision {
            rectangles.revision = VNDetectFaceRectanglesRequestRevision3
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([landmarks, rectangles])

        guard let faces = landmarks.results, !faces.isEmpty else {
            throw EngineError.noFace
        }
        guard faces.count == 1, let face = faces.first else {
            throw EngineError.multipleFaces(faces.count)
        }

        let ear = eyeAspectRatio(of: face)

        var descriptor: Descriptor? = nil
        if wantDescriptor {
            descriptor = try featureprint(of: face, in: image)
        }

        let posed = rectangles.results?.first ?? face
        return Detection(observation: face, eyeAspectRatio: ear, descriptor: descriptor,
                         pose: Pose(landmarks: face, rectangles: posed))
    }

    private static func featureprint(of face: VNFaceObservation, in image: CGImage) throws -> Descriptor {
        Descriptor(vector: try FaceEmbedder.embed(image, face: face))
    }

    public static func distance(from descriptor: Descriptor, to enrolled: [Descriptor]) -> Float? {
        var best: Float? = nil
        let a = descriptor.vector
        for candidate in enrolled {
            let b = candidate.vector
            guard a.count == b.count, !a.isEmpty else { continue }
            var dot: Float = 0
            for i in 0..<a.count { dot += a[i] * b[i] }
            let d = 1 - max(-1, min(1, dot))
            if best == nil || d < best! { best = d }
        }
        return best
    }

    private static func eyeAspectRatio(of face: VNFaceObservation) -> Double {
        guard let landmarks = face.landmarks else { return 0 }
        let ratios = [landmarks.leftEye, landmarks.rightEye].compactMap { eye -> Double? in
            guard let points = eye?.normalizedPoints, points.count >= 4 else { return nil }
            let xs = points.map { Double($0.x) }, ys = points.map { Double($0.y) }
            let width = (xs.max() ?? 0) - (xs.min() ?? 0)
            let height = (ys.max() ?? 0) - (ys.min() ?? 0)
            guard width > 0.0001 else { return nil }
            return height / width
        }
        guard !ratios.isEmpty else { return 0 }
        return ratios.reduce(0, +) / Double(ratios.count)
    }
}
