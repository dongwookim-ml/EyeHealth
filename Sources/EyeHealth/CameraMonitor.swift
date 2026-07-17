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
        /// The face is oriented toward the camera (yaw, and in enhanced mode
        /// also pitch and coarse gaze from pupil position).
        let frontal: Bool
        /// False when the eyes appear closed (enhanced mode only; true when unknown).
        let eyesOpen: Bool
    }

    /// Called on the main thread after each analyzed frame.
    var onResult: ((Detection) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.dongwookim.eyehealth.camera")
    private var currentInput: AVCaptureDeviceInput?
    private var outputAdded = false
    private var preferredDeviceID: String? // queue-confined
    private var enhanced = false // queue-confined; richer analysis on AC power
    private var lastProcessed = Date(timeIntervalSince1970: 0)
    /// Enhanced mode analyzes 2 frames/sec, light mode 1 frame/sec.
    private var minFrameInterval: TimeInterval { enhanced ? 0.5 : 1.0 }

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

    /// Enhanced mode adds face landmarks (eye openness, pupil gaze, head pitch)
    /// and a higher analysis rate. Used while on AC power.
    func setEnhanced(_ on: Bool) {
        queue.async { [weak self] in self?.enhanced = on }
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

        let rects = VNDetectFaceRectanglesRequest()
        if #available(macOS 11.0, *) { rects.revision = VNDetectFaceRectanglesRequestRevision3 }
        let landmarks = VNDetectFaceLandmarksRequest()
        let requests: [VNRequest] = enhanced ? [rects, landmarks] : [rects]

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        guard (try? handler.perform(requests)) != nil else { return }

        let faces = rects.results ?? []
        var frontal = faces.contains { observation in
            guard let yaw = observation.yaw?.doubleValue else { return true }
            var ok = abs(yaw) <= 0.7 // within ~40 degrees of facing the camera
            if enhanced, #available(macOS 12.0, *), let pitch = observation.pitch?.doubleValue {
                ok = ok && abs(pitch) <= 0.6 // not staring steeply down (phone) or up
            }
            return ok
        }
        var eyesOpen = true

        // Enhanced mode: eye openness and coarse gaze from the largest face.
        if enhanced,
           let face = (landmarks.results ?? []).max(by: {
               $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
           }),
           let marks = face.landmarks {

            // Openness = eye-contour height/width. Both eyes near-flat = closed.
            func openness(_ region: VNFaceLandmarkRegion2D?) -> Double? {
                guard let pts = region?.normalizedPoints, pts.count >= 4 else { return nil }
                let xs = pts.map { Double($0.x) }, ys = pts.map { Double($0.y) }
                let w = xs.max()! - xs.min()!
                guard w > 0 else { return nil }
                return (ys.max()! - ys.min()!) / w
            }
            let ratios = [openness(marks.leftEye), openness(marks.rightEye)].compactMap { $0 }
            if !ratios.isEmpty { eyesOpen = ratios.max()! > 0.15 }

            // Gaze: pupil offset from eye center, in half-eye-widths. Both pupils
            // hard toward a corner = looking well off to the side of the screen.
            if eyesOpen && frontal {
                func gazeOffset(_ eye: VNFaceLandmarkRegion2D?, _ pupil: VNFaceLandmarkRegion2D?) -> Double? {
                    guard let e = eye?.normalizedPoints, e.count >= 4,
                          let p = pupil?.normalizedPoints.first else { return nil }
                    let xs = e.map { Double($0.x) }
                    let half = (xs.max()! - xs.min()!) / 2
                    guard half > 0 else { return nil }
                    return (Double(p.x) - (xs.max()! + xs.min()!) / 2) / half
                }
                let offsets = [gazeOffset(marks.leftEye, marks.leftPupil),
                               gazeOffset(marks.rightEye, marks.rightPupil)].compactMap { $0 }
                if offsets.count == 2 && abs((offsets[0] + offsets[1]) / 2) > 0.5 {
                    frontal = false
                }
            }
        }

        let detection = Detection(facePresent: !faces.isEmpty, frontal: frontal, eyesOpen: eyesOpen)
        DispatchQueue.main.async { [weak self] in self?.onResult?(detection) }
    }
}
