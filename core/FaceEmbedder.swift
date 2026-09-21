import CoreML
import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// ArcFace (MobileFaceNet, `w600k_mbf`) face embedding via Core ML.
public enum FaceEmbedder {

    public enum EmbedError: Error, CustomStringConvertible {
        case modelMissing
        case landmarksMissing
        case alignmentFailed
        case inferenceFailed(String)

        public var description: String {
            switch self {
            case .modelMissing: return "face model not found in the app bundle"
            case .landmarksMissing: return "could not locate eyes, nose and mouth"
            case .alignmentFailed: return "could not align the face"
            case .inferenceFailed(let why): return "face model failed: \(why)"
            }
        }
    }

    static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]

    private static let side = 112

    private static let model: MLModel? = {
        guard let url = modelURL() else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: config)
    }()

    private static func modelURL() -> URL? {
        if let override = ProcessInfo.processInfo.environment["MACID_MODEL"] {
            return URL(fileURLWithPath: override)
        }
        if let inBundle = Bundle.main.url(forResource: "FaceEmbedding", withExtension: "mlmodelc") {
            return inBundle
        }
        let beside = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("FaceEmbedding.mlmodelc")
        return FileManager.default.fileExists(atPath: beside.path) ? beside : nil
    }

    public static var isAvailable: Bool { model != nil }

    static func fivePoints(_ face: VNFaceObservation, imageSize: CGSize) -> [CGPoint]? {
        guard let lm = face.landmarks else { return nil }

        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint]? {
            guard let region, region.pointCount > 0 else { return nil }
            return region.pointsInImage(imageSize: imageSize)
                .map { CGPoint(x: $0.x, y: imageSize.height - $0.y) }
        }
        func centroid(_ ps: [CGPoint]) -> CGPoint {
            CGPoint(x: ps.reduce(0) { $0 + $1.x } / CGFloat(ps.count),
                    y: ps.reduce(0) { $0 + $1.y } / CGFloat(ps.count))
        }

        let eyeA = points(lm.leftPupil).map(centroid) ?? points(lm.leftEye).map(centroid)
        let eyeB = points(lm.rightPupil).map(centroid) ?? points(lm.rightEye).map(centroid)
        guard var eyes = [eyeA, eyeB].compactMap({ $0 }) as [CGPoint]?, eyes.count == 2,
              let nosePoints = points(lm.nose),
              let lips = points(lm.outerLips), lips.count >= 2 else { return nil }
        eyes.sort { $0.x < $1.x }

        guard let tip = nosePoints.max(by: { $0.y < $1.y }),
              let mouthLeft = lips.min(by: { $0.x < $1.x }),
              let mouthRight = lips.max(by: { $0.x < $1.x }) else { return nil }

        return [eyes[0], eyes[1], tip, mouthLeft, mouthRight]
    }

    static func similarityTransform(from src: [CGPoint], to dst: [CGPoint]) -> CGAffineTransform? {
        guard src.count == dst.count, src.count >= 2 else { return nil }
        let n = Double(src.count)

        func mean(_ ps: [CGPoint]) -> (Double, Double) {
            (ps.reduce(0.0) { $0 + Double($1.x) } / n, ps.reduce(0.0) { $0 + Double($1.y) } / n)
        }
        let (sx, sy) = mean(src), (dx, dy) = mean(dst)

        var varSrc = 0.0, a = 0.0, b = 0.0
        for i in 0..<src.count {
            let ux = Double(src[i].x) - sx, uy = Double(src[i].y) - sy
            let vx = Double(dst[i].x) - dx, vy = Double(dst[i].y) - dy
            varSrc += ux * ux + uy * uy
            a += ux * vx + uy * vy
            b += ux * vy - uy * vx
        }
        guard varSrc > 1e-9 else { return nil }

        let scaleCos = a / varSrc, scaleSin = b / varSrc
        let tx = dx - (scaleCos * sx - scaleSin * sy)
        let ty = dy - (scaleSin * sx + scaleCos * sy)
        return CGAffineTransform(a: scaleCos, b: scaleSin,
                                 c: -scaleSin, d: scaleCos,
                                 tx: tx, ty: ty)
    }

    static func alignedCrop(_ image: CGImage, face: VNFaceObservation) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        guard let five = fivePoints(face, imageSize: size) else { throw EmbedError.landmarksMissing }
        guard let t = similarityTransform(from: five, to: template) else { throw EmbedError.alignmentFailed }

        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw EmbedError.alignmentFailed
        }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(side))
        ctx.scaleBy(x: 1, y: -1)
        ctx.concatenate(t)
        ctx.translateBy(x: 0, y: CGFloat(image.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        guard let out = ctx.makeImage() else { throw EmbedError.alignmentFailed }
        return out
    }

    public static func embed(_ image: CGImage, face: VNFaceObservation) throws -> [Float] {
        guard let model else { throw EmbedError.modelMissing }
        let crop = try alignedCrop(image, face: face)
        guard let buffer = pixelBuffer(crop) else { throw EmbedError.alignmentFailed }

        do {
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(pixelBuffer: buffer)
            ])
            let out = try model.prediction(from: input)
            guard let array = out.featureValue(for: "embedding")?.multiArrayValue else {
                throw EmbedError.inferenceFailed("no embedding in the output")
            }
            var v = [Float](repeating: 0, count: array.count)
            for i in 0..<array.count { v[i] = array[i].floatValue }
            return normalized(v)
        } catch let e as EmbedError {
            throw e
        } catch {
            throw EmbedError.inferenceFailed("\(error)")
        }
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 1e-9 else { return v }
        return v.map { $0 / norm }
    }

    private static func pixelBuffer(_ image: CGImage) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true,
                     kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                                  kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                  width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buffer
    }
}
