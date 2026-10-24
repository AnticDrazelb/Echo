import AVFoundation
import CoreImage
import UIKit

/// Capture session + per-frame styling. Runs on its own queues; the UI talks
/// to it through `CameraModel`.
final class CameraPipeline: NSObject, @unchecked Sendable {
    let frameStore = FrameStore()
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "echo.camera.session")
    private let videoQueue = DispatchQueue(label: "echo.camera.video", qos: .userInteractive)
    private let statsQueue = DispatchQueue(label: "echo.camera.stats", qos: .utility)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?

    private let lock = NSLock()
    private var renderer: StyleRenderer?
    private var settings = RenderSettings(intensity: 1)
    private var latest: CIImage?
    private var frameCount = 0
    private var statsBusy = false
    private var smoothedStats: StyleDNA?
    private var photoHandlers: [Int64: (Result<CIImage, Error>) -> Void] = [:]

    private(set) var position: AVCaptureDevice.Position = .back

    // MARK: Configuration

    func start(completion: @escaping @Sendable (Bool) -> Void) {
        sessionQueue.async {
            if self.input == nil { self.configure(position: self.position) }
            if !self.session.isRunning { self.session.startRunning() }
            completion(self.input != nil)
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func flip() {
        sessionQueue.async {
            self.position = self.position == .back ? .front : .back
            self.configure(position: self.position)
        }
    }

    private func configure(position: AVCaptureDevice.Position) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high

        if let input { session.removeInput(input) }
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video)
        guard let device, let newInput = try? AVCaptureDeviceInput(device: device), session.canAddInput(newInput) else {
            input = nil
            return
        }
        session.addInput(newInput)
        input = newInput

        if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            session.addOutput(videoOutput)
        }
        if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)].compactMap({ $0 }) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = position == .front
            }
        }
    }

    // MARK: Styling

    func setStyle(_ dna: StyleDNA?) {
        lock.lock()
        if let dna {
            renderer = StyleRenderer(reference: dna, source: smoothedStats ?? .neutral)
        } else {
            renderer = nil
        }
        lock.unlock()
        if let current = currentRenderer() {
            statsQueue.async { current.warmUp() }
        }
    }

    func setIntensity(_ value: Float) {
        lock.lock()
        settings.intensity = value
        lock.unlock()
    }

    private func currentRenderer() -> StyleRenderer? {
        lock.lock(); defer { lock.unlock() }
        return renderer
    }

    /// The most recent raw frame (used when locking a look).
    func latestFrame() -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    // MARK: Photos

    func capturePhoto(_ handler: @escaping (Result<CIImage, Error>) -> Void) {
        sessionQueue.async {
            let settings = self.photoOutput.availablePhotoCodecTypes.contains(.hevc)
                ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
                : AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            self.lock.lock()
            self.photoHandlers[settings.uniqueID] = handler
            self.lock.unlock()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

extension CameraPipeline: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let frame = CIImage(cvPixelBuffer: buffer)

        lock.lock()
        latest = frame
        frameCount += 1
        let count = frameCount
        let renderer = renderer
        let settings = settings
        let needsStats = renderer != nil && !statsBusy && count % 12 == 0
        if needsStats { statsBusy = true }
        lock.unlock()

        guard let renderer else {
            frameStore.push(frame)
            return
        }
        if needsStats { updateStats(from: frame, renderer: renderer) }
        frameStore.push(renderer.apply(frame, settings: settings, seed: count))
    }

    /// Keeps the transfer adapted to what the camera currently sees, smoothed
    /// so the look doesn't pump as the scene changes.
    private func updateStats(from frame: CIImage, renderer: StyleRenderer) {
        let small = StyleAnalyzer.sample(frame, longSide: 96)
        statsQueue.async {
            let fresh = StyleAnalyzer.analyze(color: small, texture: small)
            self.lock.lock()
            let blended = self.smoothedStats.map { StyleDNA.blend([($0, 0.7), (fresh, 0.3)]) } ?? fresh
            self.smoothedStats = blended
            self.statsBusy = false
            self.lock.unlock()
            renderer.updateSource(blended)
        }
    }
}

extension CameraPipeline: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        lock.lock()
        let handler = photoHandlers.removeValue(forKey: photo.resolvedSettings.uniqueID)
        lock.unlock()
        guard let handler else { return }
        if let error {
            handler(.failure(error))
        } else if let data = photo.fileDataRepresentation(),
                  let image = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            handler(.success(image.normalizedToOrigin()))
        } else {
            handler(.failure(MediaError.unreadable))
        }
    }
}
