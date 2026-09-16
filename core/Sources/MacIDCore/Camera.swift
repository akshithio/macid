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

    /// Called on an internal queue for every frame while running.
    private var onFrame: ((CGImage) -> Void)?

    public var isRunning: Bool { session.isRunning }

    // MARK: - Authorization

    /// Ask for camera access, blocking until the user answers.
    /// At the lock screen no prompt can appear, so this must have been granted
    /// beforehand — `faced enroll` is what triggers the prompt in practice.
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

    /// Capture a single frame, waiting up to `timeout`. Used by enrollment.
    public func grabOne(timeout: TimeInterval = 5) throws -> CGImage {
        var captured: CGImage?
        let sem = DispatchSemaphore(value: 0)
        var done = false
        let lock = NSLock()

        try start { image in
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            captured = image
            sem.signal()
        }
        defer { stop() }

        _ = sem.wait(timeout: .now() + timeout)
        guard let image = captured else {
            throw CameraError.cannotConfigure("no frame within \(Int(timeout))s")
        }
        return image
    }

    // MARK: - Frame delivery

    public func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let handler = onFrame,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        handler(cg)
    }
}
