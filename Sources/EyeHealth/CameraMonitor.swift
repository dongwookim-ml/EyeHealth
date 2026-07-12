import AVFoundation
import Vision
import CoreMedia

/// Uses the webcam + Vision to detect whether a face roughly facing the screen
/// is present. All processing is on-device; frames are analyzed and discarded,
/// never stored or transmitted.
final class CameraMonitor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    /// Called on the main thread after each analyzed frame. `true` means a face
    /// roughly facing the screen was seen.
    var onResult: ((Bool) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.dongwookim.eyehealth.camera")
    private var configured = false
    private var lastProcessed = Date(timeIntervalSince1970: 0)
    private let minFrameInterval: TimeInterval = 1.0 // analyze ~1 frame/sec

    /// Set on the main thread; reflects whether we want the session capturing.
    private(set) var isRunning = false

    var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    var permissionDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }

    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    func start() {
        guard !isRunning, isAuthorized else { return }
        isRunning = true
        queue.async { [weak self] in
            guard let self = self, self.configureIfNeeded() else { return }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    // MARK: - Private

    private func configureIfNeeded() -> Bool {
        if configured { return true }
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }

        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.low) ? .low : .medium
        if session.canAddInput(input) { session.addInput(input) }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }

        session.commitConfiguration()
        configured = true
        return true
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = Date()
        if now.timeIntervalSince(lastProcessed) < minFrameInterval { return }
        lastProcessed = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectFaceRectanglesRequest()
        if #available(macOS 11.0, *) { request.revision = VNDetectFaceRectanglesRequestRevision3 }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil else { return }

        let facing = (request.results ?? []).contains { observation in
            if let yaw = observation.yaw?.doubleValue {
                return abs(yaw) <= 0.7 // within ~40 degrees of facing the screen
            }
            return true // face present, orientation unavailable
        }

        DispatchQueue.main.async { [weak self] in self?.onResult?(facing) }
    }
}
