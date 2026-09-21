import Foundation
import AVFoundation
import CoreVideo
import CoreImage
import CoreGraphics

/// AVCaptureSession wrapper that hands out CGImages, running only while needed.
public final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    public enum CameraError: Error, CustomStringConvertible {
        case denied
        case noDevice
        case cannotConfigure(String)

        public var description: String {
            switch self {
            case .denied:
                return """
                camera access denied. Grant it in System Settings > Privacy & \
                Security > Camera, then restart the agent.
                """
            case .noDevice: return "no camera found"
            case .cannotConfigure(let why): return "camera setup failed: \(why)"
            }
        }
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var isConfigured = false
    private let queue = DispatchQueue(label: "io.akshith.macid.camera")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let sharedContext = CIContext(options: [.useSoftwareRenderer: false])

    private var onFrame: ((CGImage) -> Void)?

    private let frameLock = NSLock()
    private var _latest: CGImage?
    private var _framesDelivered = 0

    public var latestFrame: CGImage? {
        frameLock.lock(); defer { frameLock.unlock() }
        return _latest
    }

    public var framesDelivered: Int {
        frameLock.lock(); defer { frameLock.unlock() }
        return _framesDelivered
    }

    public var isRunning: Bool { session.isRunning }

    public static func ensureAuthorized() throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .video) { ok in
                granted = ok
                sem.signal()
            }
            sem.wait()
            if !granted { throw CameraError.denied }
        case .denied, .restricted:
            throw CameraError.denied
        @unknown default:
            throw CameraError.denied
        }
    }

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw CameraError.noDevice
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraError.cannotConfigure(error.localizedDescription)
        }
        guard session.canAddInput(input) else {
            throw CameraError.cannotConfigure("input rejected")
        }
        session.addInput(input)

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw CameraError.cannotConfigure("output rejected")
        }
        session.addOutput(output)

        isConfigured = true
    }

    public func start(onFrame: @escaping (CGImage) -> Void) throws {
        guard !session.isRunning else { return }
        try Camera.ensureAuthorized()
        try configureIfNeeded()

        self.onFrame = onFrame
        frameLock.lock()
        _latest = nil
        _framesDelivered = 0
        frameLock.unlock()

        session.startRunning()
    }

    public func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
        onFrame = nil
    }

    @discardableResult
    public func warmUp(minFrames: Int = 12,
                       minSeconds: TimeInterval = 0.7,
                       timeout: TimeInterval = 5) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if framesDelivered >= minFrames,
               Date().timeIntervalSince(start) >= minSeconds {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return framesDelivered > 0
    }

    public static func meanLuminance(of image: CGImage) -> Double {
        let ci = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ci,
            kCIInputExtentKey: CIVector(cgRect: ci.extent),
        ]), let output = filter.outputImage else { return -1 }

        var pixel = [UInt8](repeating: 0, count: 4)
        sharedContext.render(output,
                             toBitmap: &pixel,
                             rowBytes: 4,
                             bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                             format: .RGBA8,
                             colorSpace: CGColorSpaceCreateDeviceRGB())

        let r = Double(pixel[0]), g = Double(pixel[1]), b = Double(pixel[2])
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
    }

    public func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = onFrame
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }

        frameLock.lock()
        _latest = cg
        _framesDelivered += 1
        frameLock.unlock()

        handler?(cg)
    }
}
