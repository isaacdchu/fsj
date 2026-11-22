import AVFoundation
import Foundation
import Observation
import Photos

/// A recorded clip to mark takeoff and landing on.
nonisolated struct VideoClip: Equatable, Sendable {
    /// Nil for the made-up clip used where there is no camera (Simulator).
    var url: URL?
    var fps: Double
    var frameCount: Int

    var lastFrame: Int { max(0, frameCount - 1) }

    /// Milliseconds from the start of the clip to this frame.
    func ms(at frame: Int) -> Double {
        Double(frame) / fps * 1000
    }

    /// The made-up 240 fps clip from the mockup: a jump from frame 300 to 428.
    static let simulated = VideoClip(url: nil, fps: 240, frameCount: 768)
    static let simulatedTakeoff = 300
    static let simulatedLanding = 428
}

nonisolated enum CameraError: LocalizedError, Sendable {
    case notAllowed
    case noCamera
    case notReady
    case photosNotAllowed

    var errorDescription: String? {
        switch self {
        case .notAllowed: "Camera access is off for FSJ. Turn it on in the Settings app."
        case .noCamera: "No camera is available."
        case .notReady: "The camera isn't ready yet."
        case .photosNotAllowed: "FSJ can't add videos to Photos. Allow it in the Settings app."
        }
    }
}

/// The back camera, set to its highest frame rate up to 240 fps, recording
/// to a movie file. Where there is no camera (Simulator) it reports
/// `isSimulated` and hands back `VideoClip.simulated` instead.
@Observable
final class CameraRecorder {
    enum State: Equatable {
        case idle
        case preparing
        case ready
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var fps: Double = 240

    @ObservationIgnored let capture = CameraCapture()
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var simulatedStart: Date?

    var isSimulated: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Ask for access, set the camera up once, and start the preview.
    func prepare() async {
        guard !isSimulated else {
            state = .ready
            return
        }
        guard state != .preparing else { return }
        state = .preparing
        do {
            guard await Self.cameraAllowed() else { throw CameraError.notAllowed }
            if !configured {
                fps = try await capture.configure()
                configured = true
            }
            await capture.startRunning()
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Stop the preview to save power (not while recording).
    func pause() {
        guard !isSimulated, configured else { return }
        Task { await capture.stopRunningUnlessRecording() }
        if state == .ready { state = .idle }
    }

    func startRecording() async throws {
        if isSimulated {
            simulatedStart = .now
            return
        }
        guard state == .ready else { throw CameraError.notReady }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsj-\(UUID().uuidString)")
            .appendingPathExtension("mov")
        try await capture.startRecording(to: url)
    }

    func stopRecording() async throws -> VideoClip {
        if isSimulated {
            simulatedStart = nil
            try await Task.sleep(for: .milliseconds(300))
            return .simulated
        }
        let url = try await capture.stopRecording()
        return try await Self.clip(at: url, fallbackFPS: fps)
    }

    func discard(_ clip: VideoClip) {
        if let url = clip.url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Add the clip to Photos, then remove the temporary file.
    func saveToPhotos(_ clip: VideoClip) async throws {
        guard let url = clip.url else { return }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw CameraError.photosNotAllowed }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
        }
        try? FileManager.default.removeItem(at: url)
    }

    private static func cameraAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    private static func clip(at url: URL, fallbackFPS: Double) async throws -> VideoClip {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        var fps = fallbackFPS
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let rate = try await track.load(.nominalFrameRate)
            if rate > 0 { fps = Double(rate) }
        }
        let frames = max(1, Int((duration.seconds * fps).rounded(.down)))
        return VideoClip(url: url, fps: fps, frameCount: frames)
    }
}

/// AVFoundation side, kept off the main actor. All session work runs on
/// `queue`.
nonisolated final class CameraCapture: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "fsj.camera")
    private var finished: CheckedContinuation<URL, Error>?

    /// Set up the back camera at its highest frame rate up to 240 fps.
    /// Returns the frame rate it chose.
    func configure() async throws -> Double {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Double, Error>) in
            queue.async {
                do {
                    cont.resume(returning: try self.configureOnQueue())
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func configureOnQueue() throws -> Double {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority
        guard session.canAddInput(input), session.canAddOutput(output) else { throw CameraError.noCamera }
        session.addInput(input)
        session.addOutput(output)

        // Highest frame rate up to 240, then the widest picture up to 1080p.
        func rate(_ f: AVCaptureDevice.Format) -> Double {
            min(240, f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }
        func width(_ f: AVCaptureDevice.Format) -> Int32 {
            let w = CMVideoFormatDescriptionGetDimensions(f.formatDescription).width
            return w <= 1920 ? w : 0
        }
        let best = device.formats.max { a, b in
            (rate(a), width(a)) < (rate(b), width(b))
        }
        var fps = 30.0
        if let best {
            fps = rate(best)
            try device.lockForConfiguration()
            device.activeFormat = best
            let frame = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
            device.activeVideoMinFrameDuration = frame
            device.activeVideoMaxFrameDuration = frame
            device.unlockForConfiguration()
        }
        return fps
    }

    func startRunning() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if !self.session.isRunning { self.session.startRunning() }
                cont.resume()
            }
        }
    }

    func stopRunningUnlessRecording() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.session.isRunning, !self.output.isRecording { self.session.stopRunning() }
                cont.resume()
            }
        }
    }

    func startRecording(to url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.session.isRunning, !self.output.isRecording else {
                    cont.resume(throwing: CameraError.notReady)
                    return
                }
                self.output.startRecording(to: url, recordingDelegate: self)
                cont.resume()
            }
        }
    }

    /// Stop recording and wait until the file is written.
    func stopRecording() async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            queue.async {
                guard self.output.isRecording else {
                    cont.resume(throwing: CameraError.notReady)
                    return
                }
                self.finished = cont
                self.output.stopRecording()
            }
        }
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        queue.async {
            guard let cont = self.finished else { return }
            self.finished = nil
            // AVFoundation can report an error even though the file is fine
            // (for example when stopped by a disk-space limit).
            if let error, (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true {
                cont.resume(throwing: error)
            } else {
                cont.resume(returning: outputFileURL)
            }
        }
    }
}
