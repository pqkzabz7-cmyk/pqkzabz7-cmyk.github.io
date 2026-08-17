import AVFoundation
import CoreImage
import SwiftUI
import Vision

final class CameraManager: NSObject, ObservableObject {
    private static let temporaryRecordingPrefix = "MirrorFocus-"

    enum Status: Equatable {
        case requestingPermission
        case configuring
        case ready
        case denied
        case unavailable(String)
    }

    let session = AVCaptureSession()

    @Published private(set) var status: Status = .requestingPermission
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var faceFeaturePositions = FaceFeaturePositions()
    @Published private(set) var cameraFrameSize: CGSize = .zero
    @Published var frozenFrame: CGImage?
    @Published var recordedClip: RecordedClip?

    private(set) var frozenFaceFeaturePositions: FaceFeaturePositions?
    private(set) var frozenCameraFrameSize: CGSize?

    private let sessionQueue = DispatchQueue(label: "jp.abekazuya.mirrorfocus.camera.session")
    private let videoQueue = DispatchQueue(label: "jp.abekazuya.mirrorfocus.camera.frames", qos: .userInteractive)
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let frameLock = NSLock()

    private var latestPixelBuffer: CVPixelBuffer?
    private var isConfigured = false
    private var recordingRequested = false
    private var discardCurrentRecording = false
    private var completedRecordingURL: URL?
    private var lastFaceDetectionTime: TimeInterval = 0
    private var smoothedFaceFeaturePositions = FaceFeaturePositions()
    private var consecutiveMissingFaces = 0

    override init() {
        super.init()
        session.automaticallyConfiguresApplicationAudioSession = false
        sessionQueue.async {
            Self.removeStaleTemporaryRecordings()
        }
        requestPermissionsAndConfigure()
    }

    deinit {
        session.stopRunning()
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning, !self.movieOutput.isRecording else { return }
            self.session.stopRunning()
        }
    }

    func toggleFreeze() {
        precondition(Thread.isMainThread)

        if frozenFrame != nil {
            frozenFrame = nil
            frozenFaceFeaturePositions = nil
            frozenCameraFrameSize = nil
            return
        }

        frameLock.lock()
        let pixelBuffer = latestPixelBuffer
        frameLock.unlock()

        guard let pixelBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        frozenFaceFeaturePositions = faceFeaturePositions
        frozenCameraFrameSize = cameraFrameSize
        frozenFrame = imageContext.createCGImage(image, from: image.extent)
    }

    func resumeLiveView() {
        DispatchQueue.main.async { [weak self] in
            self?.frozenFrame = nil
            self?.frozenFaceFeaturePositions = nil
            self?.frozenCameraFrameSize = nil
        }
    }

    func startRecording(mirrored: Bool) {
        resumeLiveView()

        sessionQueue.async { [weak self] in
            guard let self,
                  self.isConfigured,
                  self.session.isRunning,
                  !self.movieOutput.isRecording else {
                self?.recordingRequested = false
                return
            }

            self.recordingRequested = true
            self.discardCurrentRecording = false

            if let connection = self.movieOutput.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
                connection.automaticallyAdjustsVideoMirroring = false
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = mirrored
                }
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(Self.temporaryRecordingPrefix)\(UUID().uuidString)")
                .appendingPathExtension("mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.recordingRequested = false
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
        }
    }

    func cancelRecording() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.recordingRequested = false
            self.discardCurrentRecording = true
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
            }
        }
    }

    func discardRecordedClip() {
        precondition(Thread.isMainThread)

        let url = completedRecordingURL ?? recordedClip?.url
        completedRecordingURL = nil
        recordedClip = nil

        guard let url else { return }
        sessionQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func removeStaleTemporaryRecordings() {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in files where url.lastPathComponent.hasPrefix(temporaryRecordingPrefix)
            && url.pathExtension.lowercased() == "mov" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func requestPermissionsAndConfigure() {
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

        switch cameraStatus {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureSession()
                } else {
                    DispatchQueue.main.async { self.status = .denied }
                }
            }
        case .denied, .restricted:
            status = .denied
        @unknown default:
            status = .denied
        }
    }

    private func configureSession() {
        DispatchQueue.main.async { [weak self] in
            self?.status = .configuring
        }

        sessionQueue.async { [weak self] in
            guard let self, !self.isConfigured else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            do {
                guard let camera = AVCaptureDevice.default(
                    .builtInWideAngleCamera,
                    for: .video,
                    position: .front
                ) else {
                    throw CameraError.frontCameraUnavailable
                }

                Self.configureBrighterMirrorExposure(for: camera)

                let cameraInput = try AVCaptureDeviceInput(device: camera)
                guard self.session.canAddInput(cameraInput) else {
                    throw CameraError.cannotAddCameraInput
                }
                self.session.addInput(cameraInput)

                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                guard self.session.canAddOutput(self.videoOutput) else {
                    throw CameraError.cannotAddVideoOutput
                }
                self.session.addOutput(self.videoOutput)

                guard self.session.canAddOutput(self.movieOutput) else {
                    throw CameraError.cannotAddMovieOutput
                }
                self.session.addOutput(self.movieOutput)

                if let connection = self.videoOutput.connection(with: .video),
                   connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }

                self.session.commitConfiguration()
                self.isConfigured = true
                self.session.startRunning()

                DispatchQueue.main.async {
                    self.status = .ready
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.status = .unavailable(error.localizedDescription)
                }
            }
        }
    }

    private static func configureBrighterMirrorExposure(for camera: AVCaptureDevice) {
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }

            let preferredBias: Float = 0.40
            let supportedBias = min(
                max(preferredBias, camera.minExposureTargetBias),
                camera.maxExposureTargetBias
            )
            camera.setExposureTargetBias(supportedBias)

            if camera.isLowLightBoostSupported {
                camera.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
        } catch {
            // 自動露出はそのまま利用できるため、設定失敗時もカメラを継続する。
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        frameLock.lock()
        latestPixelBuffer = pixelBuffer
        frameLock.unlock()

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFaceDetectionTime >= 0.08 else { return }
        lastFaceDetectionTime = now
        detectFaceFeatures(in: pixelBuffer)
    }

    private func detectFaceFeatures(in pixelBuffer: CVPixelBuffer) {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)

        do {
            try handler.perform([request])

            guard let face = request.results?.max(by: {
                $0.boundingBox.width * $0.boundingBox.height
                    < $1.boundingBox.width * $1.boundingBox.height
            }) else {
                handleMissingFace()
                return
            }

            consecutiveMissingFaces = 0
            let detected = Self.featurePositions(from: face)
            smoothedFaceFeaturePositions = smoothedFaceFeaturePositions.smoothed(toward: detected)

            let frameSize = CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
            let positions = smoothedFaceFeaturePositions

            DispatchQueue.main.async { [weak self] in
                self?.cameraFrameSize = frameSize
                self?.faceFeaturePositions = positions
            }
        } catch {
            handleMissingFace()
        }
    }

    private func handleMissingFace() {
        consecutiveMissingFaces += 1
        guard consecutiveMissingFaces >= 12 else { return }
        smoothedFaceFeaturePositions = FaceFeaturePositions()

        DispatchQueue.main.async { [weak self] in
            self?.faceFeaturePositions = FaceFeaturePositions()
        }
    }

    private static func featurePositions(from face: VNFaceObservation) -> FaceFeaturePositions {
        let box = face.boundingBox
        let landmarks = face.landmarks

        let detectedEyes = [
            normalizedCenter(of: landmarks?.leftEye, in: box),
            normalizedCenter(of: landmarks?.rightEye, in: box)
        ]
        .compactMap { $0 }
        .sorted { $0.x < $1.x }

        // 非ミラーの前面カメラ画像では、本人の右目が画像の左側に映る。
        let rightEye = detectedEyes.count == 2 ? detectedEyes.first : nil
        let leftEye = detectedEyes.count == 2 ? detectedEyes.last : nil

        let nose = normalizedCenter(of: landmarks?.nose ?? landmarks?.noseCrest, in: box)
        let mouth = normalizedCenter(of: landmarks?.outerLips ?? landmarks?.innerLips, in: box)
        return FaceFeaturePositions(
            leftEye: leftEye,
            rightEye: rightEye,
            nose: nose,
            mouth: mouth
        )
    }

    private static func normalizedCenter(
        of region: VNFaceLandmarkRegion2D?,
        in faceBox: CGRect
    ) -> CGPoint? {
        guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }

        let localCenter = average(points.map { CGPoint(x: $0.x, y: $0.y) })
        guard let localCenter else { return nil }

        return CGPoint(
            x: faceBox.minX + localCenter.x * faceBox.width,
            y: 1 - (faceBox.minY + localCenter.y * faceBox.height)
        )
    }

    private static func average(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let total = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        return CGPoint(x: total.x / CGFloat(points.count), y: total.y / CGFloat(points.count))
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        sessionQueue.async { [weak self] in
            guard let self, !self.recordingRequested, self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }

        DispatchQueue.main.async { [weak self] in
            self?.isRecording = true
            self?.recordingStartedAt = Date()
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let shouldDiscard = self.discardCurrentRecording
            self.recordingRequested = false
            self.discardCurrentRecording = false

            DispatchQueue.main.async {
                self.isRecording = false
                self.recordingStartedAt = nil

                if shouldDiscard {
                    try? FileManager.default.removeItem(at: outputFileURL)
                } else if error == nil, FileManager.default.fileExists(atPath: outputFileURL.path) {
                    if let previousURL = self.completedRecordingURL,
                       previousURL != outputFileURL {
                        try? FileManager.default.removeItem(at: previousURL)
                    }
                    self.completedRecordingURL = outputFileURL
                    self.recordedClip = RecordedClip(url: outputFileURL)
                } else {
                    try? FileManager.default.removeItem(at: outputFileURL)
                }
            }
        }
    }
}

private enum CameraError: LocalizedError {
    case frontCameraUnavailable
    case cannotAddCameraInput
    case cannotAddVideoOutput
    case cannotAddMovieOutput

    var errorDescription: String? {
        switch self {
        case .frontCameraUnavailable:
            "前面カメラを利用できません。実機でお試しください。"
        case .cannotAddCameraInput:
            "カメラを開始できませんでした。"
        case .cannotAddVideoOutput:
            "カメラ映像を表示できませんでした。"
        case .cannotAddMovieOutput:
            "録画機能を開始できませんでした。"
        }
    }
}
