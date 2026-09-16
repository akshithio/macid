import Foundation
import AVFoundation
import CoreVideo
import CoreImage
import CoreGraphics

/// Thin wrapper over AVCaptureSession that hands out CGImages.
///
/// The session is started only while it is needed and torn down immediately
/// after. That is partly power and partly honesty: the camera indicator light
/// is wired to the hardware, so the light being on exactly when we are looking,
/// and off otherwise, is the only truthful signal the user gets.
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
    private let queue = DispatchQueue(label: "io.akshith.macid.camera")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let sharedContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Called on an internal queue for every frame while running.
    private var onFrame: ((CGImage) -> Void)?

    private let frameLock = NSLock()
    private var _latest: CGImage?
    private var _framesDelivered = 0

    /// The most recent frame, or nil before the first one arrives.
    public var latestFrame: CGImage? {
        frameLock.lock(); defer { frameLock.unlock() }
        return _latest
    }

    public var framesDelivered: Int {
        frameLock.lock(); defer { frameLock.unlock() }
        return _framesDelivered
    }

    public var isRunning: Bool { session.isRunning }

    // MARK: - Authorization

    /// Ask for camera access, blocking until the user answers.
    /// At the lock screen no prompt can appear, so this must have been granted
    /// beforehand — `macid enroll` is what triggers the prompt in practice.
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

    // MARK: - Lifecycle

    public func start(onFrame: @escaping (CGImage) -> Void) throws {
        guard !session.isRunning else { return }
        try Camera.ensureAuthorized()
        self.onFrame = onFrame

        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video) else {
            session.commitConfiguration()
            throw CameraError.noDevice
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw CameraError.cannotConfigure("input rejected")
            }
            session.addInput(input)
        } catch let e as CameraError {
            session.commitConfiguration()
            throw e
        } catch {
            session.commitConfiguration()
            throw CameraError.cannotConfigure(error.localizedDescription)
        }

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        // Recognition is slower than the frame rate; dropping is correct here,
        // a backlog of stale frames helps nobody.
        output.alwaysDiscardsLateVideoFrames = true
        frameLock.lock()
        _latest = nil
        _framesDelivered = 0
        frameLock.unlock()

        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraError.cannotConfigure("output rejected")
        }
        session.addOutput(output)
        session.commitConfiguration()

        session.startRunning()
    }

    public func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        onFrame = nil
    }

    /// Block until the sensor has settled.
    ///
    /// The first frames out of a webcam arrive before auto-exposure and gain
    /// have converged, and they are typically black. Anything that looks at a
    /// frame for content — face detection above all — has to wait these out or
    /// it is reading a black rectangle and concluding there is nobody there.
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

    /// Mean luminance of a frame, 0 (black) to 1 (white).
    ///
    /// Used to tell "nobody is in front of the camera" apart from "the camera
    /// is handing us black frames", which look identical to a face detector and
    /// need completely different advice.
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

    /// Capture one settled frame. Starts the session if it is not already
    /// running; prefer keeping it running and reading `latestFrame` when you
    /// need several frames in a row.
    public func grabOne(timeout: TimeInterval = 6) throws -> CGImage {
        let wasRunning = session.isRunning
        if !wasRunning { try start { _ in } }
        defer { if !wasRunning { stop() } }

        _ = warmUp(timeout: timeout)
        guard let image = latestFrame else {
            throw CameraError.cannotConfigure("no frame within \(Int(timeout))s")
        }
        return image
    }

    // MARK: - Frame delivery

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
