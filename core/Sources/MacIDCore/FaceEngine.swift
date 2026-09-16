import Foundation
import Vision
import CoreImage
import CoreGraphics

/// Turns a camera frame into something comparable, and compares it.
///
/// Recognition uses `VNGenerateImageFeaturePrintRequest` over a tight, aligned
/// face crop. That request is a general-purpose image descriptor rather than a
/// face-recognition model, which matters: it is good at "is this the same face
/// I enrolled, or nobody I know", and weaker than a dedicated embedding like
/// ArcFace at telling two similar faces apart. It is used here because it ships
/// with the OS — no model to download, convert, or keep in sync. `Descriptor`
/// is deliberately the only type the rest of the agent sees, so swapping in a
/// CoreML embedding later touches this file and nothing else.
public enum FaceEngine {

    public struct Descriptor {
        public let print: VNFeaturePrintObservation
    }

    public struct Detection {
        public let observation: VNFaceObservation
        /// Eye aspect ratio, averaged over both eyes. Drops sharply on a blink.
        public let eyeAspectRatio: Double
        public let descriptor: Descriptor?
    }

    public enum EngineError: Error, CustomStringConvertible {
        case noFace
        case multipleFaces(Int)
        case cropFailed
        case featureprintFailed

        public var description: String {
            switch self {
            case .noFace: return "no face in frame"
            case .multipleFaces(let n): return "\(n) faces in frame, need exactly one"
            case .cropFailed: return "could not crop face region"
            case .featureprintFailed: return "could not compute featureprint"
            }
        }
    }

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Detection

    /// Detect exactly one face and describe it. `wantDescriptor: false` skips
    /// the expensive featureprint pass — used for the cheap liveness frames.
    public static func analyze(_ image: CGImage, wantDescriptor: Bool = true) throws -> Detection {
        let landmarks = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([landmarks])

        guard let faces = landmarks.results, !faces.isEmpty else {
            throw EngineError.noFace
        }
        // More than one face at the lock screen is ambiguous at best and someone
        // reading over your shoulder at worst. Refuse rather than pick.
        guard faces.count == 1, let face = faces.first else {
            throw EngineError.multipleFaces(faces.count)
        }

        let ear = eyeAspectRatio(of: face)

        var descriptor: Descriptor? = nil
        if wantDescriptor {
            descriptor = try featureprint(of: face, in: image)
        }

        return Detection(observation: face, eyeAspectRatio: ear, descriptor: descriptor)
    }

    // MARK: - Cropping + featureprint

    /// Crop to the face with a margin, normalize to a fixed size, and describe it.
    /// The fixed size matters: featureprint distance is sensitive to scale, so an
    /// enrolled face captured close up must be normalized the same way as one
    /// captured at arm's length.
    private static func featureprint(of face: VNFaceObservation, in image: CGImage) throws -> Descriptor {
        let w = CGFloat(image.width), h = CGFloat(image.height)

        // Vision's boundingBox is normalized with a bottom-left origin.
        var rect = CGRect(
            x: face.boundingBox.origin.x * w,
            y: (1 - face.boundingBox.origin.y - face.boundingBox.height) * h,
            width: face.boundingBox.width * w,
            height: face.boundingBox.height * h
        )

        let margin: CGFloat = 0.25
        rect = rect.insetBy(dx: -rect.width * margin, dy: -rect.height * margin)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !rect.isNull, rect.width > 40, rect.height > 40,
              let cropped = image.cropping(to: rect) else {
            throw EngineError.cropFailed
        }

        guard let normalized = resize(cropped, to: CGSize(width: 224, height: 224)) else {
            throw EngineError.cropFailed
        }

        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: normalized, orientation: .up, options: [:])
        try handler.perform([request])

        guard let print = request.results?.first as? VNFeaturePrintObservation else {
            throw EngineError.featureprintFailed
        }
        return Descriptor(print: print)
    }

    private static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        let ci = CIImage(cgImage: image)
        let scaled = ci.transformed(by: CGAffineTransform(
            scaleX: size.width / CGFloat(image.width),
            y: size.height / CGFloat(image.height)
        ))
        return ciContext.createCGImage(
            scaled,
            from: CGRect(origin: .zero, size: size)
        )
    }

    // MARK: - Comparison

    /// Distance to the nearest enrolled descriptor. Lower is more similar.
    /// Returns nil if nothing is enrolled or the comparison fails outright.
    public static func distance(from descriptor: Descriptor, to enrolled: [Descriptor]) -> Float? {
        var best: Float? = nil
        for candidate in enrolled {
            var d: Float = 0
            do {
                try descriptor.print.computeDistance(&d, to: candidate.print)
            } catch {
                continue
            }
            if best == nil || d < best! { best = d }
        }
        return best
    }

    // MARK: - Liveness

    /// Eye aspect ratio: eye height over eye width. A open eye sits well above
    /// the blink threshold; a closed one collapses toward zero. A printed photo
    /// holds a constant value forever, which is exactly what we look for.
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
