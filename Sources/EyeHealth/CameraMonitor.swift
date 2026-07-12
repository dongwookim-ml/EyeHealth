import AVFoundation
import Vision
import CoreMedia

/// Uses a camera + Vision to detect whether a face is visible and whether it
/// roughly faces the camera. All processing is on-device; frames are analyzed
/// and discarded, never stored or transmitted.
final class CameraMonitor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    struct Detection {
        /// A face is visible to the camera.
        let facePresent: Bool
        /// At least one visible face is within ~40 degrees of facing the camera.
        let frontal: Bool
    }

    /// Called on the main thread after each analyzed frame.
    var onResult: ((Detection) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.dongwookim.eyehealth.camera")
    private var currentInput: AVCaptureDeviceInput?
    private var outputAdded = false
    private var preferredDeviceID: String? // queue-confined
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

    /// Connected cameras, for the device-picker menu.
    static func availableCameras() -> [(id: String, name: String)] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(.external)
            types.append(.continuityCamera)
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        return discovery.devices.map { ($0.uniqueID, $0.localizedName) }
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

    /// Selects the camera to use (nil = system default). Takes effect
    /// immediately if the session is running.
    func setPreferredDevice(_ id: String?) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.preferredDeviceID = id
            if self.session.isRunning { self.configure() }
        }
    }

    func start() {
        guard !isRunning, isAuthorized else { return }
        isRunning = true
        queue.async { [weak self] in
            guard let self = self else { return }
            self.configure()
            if self.currentInput != nil, !self.session.isRunning { self.session.startRunning() }
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

    /// Ensures the session has the frame output and an input matching the
    /// preferred device. Runs on `queue`.
    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if !outputAdded {
            session.sessionPreset = session.canSetSessionPreset(.low) ? .low : .medium
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(output) {
                session.addOutput(output)
                outputAdded = true
            }
        }

        let wanted = resolveDevice()
        if currentInput?.device.uniqueID != wanted?.uniqueID {
            if let old = currentInput {
                session.removeInput(old)
                currentInput = nil
            }
            if let device = wanted,
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
            }
        }
    }

    private func resolveDevice() -> AVCaptureDevice? {
        if let id = preferredDeviceID, let device = AVCaptureDevice(uniqueID: id) {
            return device
        }
        return AVCaptureDevice.default(for: .video)
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

        let faces = request.results ?? []
        let frontal = faces.contains { observation in
            if let yaw = observation.yaw?.doubleValue {
                return abs(yaw) <= 0.7 // within ~40 degrees of facing the camera
            }
            return true // face present, orientation unavailable
        }
        let detection = Detection(facePresent: !faces.isEmpty, frontal: frontal)

        DispatchQueue.main.async { [weak self] in self?.onResult?(detection) }
    }
}
