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
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    // Recording state, touched only on `videoQueue`.
    private var recorder: StyledRecorder?
    private var wantsRecording = false

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

    /// Adds the microphone (once permission is granted) so videos have sound.
    func enableAudio(_ done: @escaping @Sendable () -> Void) {
        sessionQueue.async {
            defer { done() }
            guard self.audioInput == nil,
                  AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                  let mic = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: mic)
            else { return }
            self.session.beginConfiguration()
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                self.audioInput = input
            }
            if !self.session.outputs.contains(self.audioOutput), self.session.canAddOutput(self.audioOutput) {
                self.audioOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                self.session.addOutput(self.audioOutput)
            }
            self.session.commitConfiguration()
        }
    }

    // MARK: Video recording

    func startRecording() {
        videoQueue.async { self.wantsRecording = true }
    }

    /// Finishes the file and returns its URL (nil if nothing was recorded).
    func stopRecording(_ completion: @escaping @Sendable (URL?) -> Void) {
        videoQueue.async {
            self.wantsRecording = false
            guard let recorder = self.recorder else { return completion(nil) }
            self.recorder = nil
            recorder.finish(completion)
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

extension CameraPipeline: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            recorder?.appendAudio(sampleBuffer)
            return
        }
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

        let output: CIImage
        if let renderer {
            if needsStats { updateStats(from: frame, renderer: renderer) }
            output = renderer.apply(frame, settings: settings, seed: count)
        } else {
            output = frame
        }
        frameStore.push(output)
        WatchBridge.shared.offerFrame(output)
        record(output, at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
               width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    }

    private func record(_ image: CIImage, at time: CMTime, width: Int, height: Int) {
        guard wantsRecording else { return }
        if recorder == nil {
            let audio = audioInput != nil ? audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) : nil
            recorder = StyledRecorder(width: width, height: height, audioSettings: audio, start: time)
            if recorder == nil { wantsRecording = false }
        }
        recorder?.appendVideo(image, at: time)
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

/// Writes already-styled frames (plus microphone audio) to a .mov file.
private final class StyledRecorder {
    let url: URL
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audio: AVAssetWriterInput?
    private let start: CMTime

    init?(width: Int, height: Int, audioSettings: [String: Any]?, start: CMTime) {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("Echo-\(UUID().uuidString).mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        video.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        guard writer.canAdd(video) else { return nil }
        writer.add(video)
        var audio: AVAssetWriterInput?
        if let audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audio = input
            }
        }
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: start)
        self.writer = writer
        self.video = video
        self.adaptor = adaptor
        self.audio = audio
        self.start = start
    }

    func appendVideo(_ image: CIImage, at time: CMTime) {
        guard writer.status == .writing, video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        RenderEngine.shared.context.render(image, to: buffer, bounds: image.extent, colorSpace: RenderEngine.sRGB)
        adaptor.append(buffer, withPresentationTime: time)
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        guard writer.status == .writing, let audio, audio.isReadyForMoreMediaData,
              CMSampleBufferGetPresentationTimeStamp(sample) >= start
        else { return }
        audio.append(sample)
    }

    func finish(_ completion: @escaping @Sendable (URL?) -> Void) {
        guard writer.status == .writing else { return completion(nil) }
        video.markAsFinished()
        audio?.markAsFinished()
        let url = url
        writer.finishWriting { [writer] in
            completion(writer.status == .completed ? url : nil)
        }
    }
}
