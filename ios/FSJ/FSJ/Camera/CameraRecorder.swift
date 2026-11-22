import AVFoundation
import Foundation
import Observation
import Photos

/// A recorded clip to mark takeoff and landing on.
nonisolated struct VideoClip: Equatable, Sendable {
    /// Nil for the made-up clip used where there is no camera (Simulator).
    var url: URL?
    /// Nominal frame rate.
    var fps: Double
    /// When each frame was captured, on the phone's host clock (seconds),
    /// one per frame in the file. The pods are synced to the same clock.
    var frameTimes: [Double]

    init(url: URL?, fps: Double, frameTimes: [Double]) {
        self.url = url
        self.fps = fps
        self.frameTimes = frameTimes.isEmpty ? [0] : frameTimes
    }

    /// Evenly spaced frames starting at `startHost`.
    init(url: URL?, fps: Double, frameCount: Int, startHost: Double = 0) {
        self.init(url: url, fps: fps, frameTimes: (0..<max(1, frameCount)).map { startHost + Double($0) / fps })
    }

    var frameCount: Int { frameTimes.count }
    var lastFrame: Int { max(0, frameCount - 1) }

    /// Host time of a frame.
    func hostTime(at frame: Int) -> Double {
        frameTimes[min(max(frame, 0), lastFrame)]
    }

    /// Milliseconds from the start of the clip to this frame.
    func ms(at frame: Int) -> Double {
        (hostTime(at: frame) - frameTimes[0]) * 1000
    }

    /// Where a host time falls, in (fractional) frames. Times outside the
    /// clip are extended at the nominal frame rate.
    func framePosition(ofHost t: Double) -> Double {
        let first = frameTimes[0], last = frameTimes[lastFrame]
        if t <= first || lastFrame == 0 { return (t - first) * fps }
        if t >= last { return Double(lastFrame) + (t - last) * fps }
        // Last frame at or before t.
        var lo = 0, hi = lastFrame
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if frameTimes[mid] <= t { lo = mid } else { hi = mid }
        }
        let span = frameTimes[hi] - frameTimes[lo]
        return Double(lo) + (span > 0 ? (t - frameTimes[lo]) / span : 0)
    }

    /// The made-up 240 fps clip from the mockup: a jump from frame 300 to 428.
    static let simulated = VideoClip(url: nil, fps: 240, frameCount: 768)
    static let simulatedTakeoff = 300
    static let simulatedLanding = 428

    static func simulated(startHost: Double) -> VideoClip {
        VideoClip(url: nil, fps: 240, frameCount: 768, startHost: startHost)
    }
}

nonisolated enum CameraError: LocalizedError, Sendable {
    case notAllowed
    case noCamera
    case notReady
    case photosNotAllowed
    case noFrames

    var errorDescription: String? {
        switch self {
        case .notAllowed: "Camera access is off for FSJ. Turn it on in the Settings app."
        case .noCamera: "No camera is available."
        case .notReady: "The camera isn't ready yet."
        case .photosNotAllowed: "FSJ can't add videos to Photos. Allow it in the Settings app."
        case .noFrames: "The camera recorded no frames."
        }
    }
}

/// The back camera, set to its highest frame rate up to 240 fps, recording
/// to a movie file and noting each frame's time on the phone's clock. Where there is no camera (Simulator) it reports
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
    @ObservationIgnored private var simulatedStart: Double?

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
            let now = HostClock.now()
            simulatedStart = now
            SimulatedScene.videoStarted(at: now)
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
            let start = simulatedStart ?? HostClock.now()
            simulatedStart = nil
            try await Task.sleep(for: .milliseconds(300))
            return .simulated(startHost: start)
        }
        let recording = try await capture.stopRecording()
        return VideoClip(url: recording.url, fps: fps, frameTimes: recording.frameTimes)
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
}

/// A finished recording: the movie file and each frame's host time.
nonisolated struct CameraRecording: Sendable {
    var url: URL
    var frameTimes: [Double]
}

/// AVFoundation side, kept off the main actor. Session work and every
/// camera frame run on `queue`. Frames go through a video data output into
/// an asset writer, so each frame's capture time is known exactly.
nonisolated final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "fsj.camera")

    // Only touched on `queue`.
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private var frameTimes: [Double] = []

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
        output.alwaysDiscardsLateVideoFrames = false
        output.setSampleBufferDelegate(self, queue: queue)
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
                if self.session.isRunning, self.writer == nil { self.session.stopRunning() }
                cont.resume()
            }
        }
    }

    func startRecording(to url: URL) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.startWriting(to: url)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func startWriting(to url: URL) throws {
        guard session.isRunning, writer == nil else { throw CameraError.notReady }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: output.recommendedVideoSettingsForAssetWriter(writingTo: .mov)
        )
        input.expectsMediaDataInRealTime = true
        // Camera frames arrive landscape; the phone is held upright.
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        guard writer.canAdd(input) else { throw CameraError.notReady }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CameraError.notReady }
        frameTimes = []
        sessionStarted = false
        self.writer = writer
        self.input = input
    }

    /// Stop recording and wait until the file is written.
    func stopRecording() async throws -> CameraRecording {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CameraRecording, Error>) in
            queue.async {
                guard let writer = self.writer, let input = self.input else {
                    cont.resume(throwing: CameraError.notReady)
                    return
                }
                self.writer = nil
                self.input = nil
                let times = self.frameTimes
                self.frameTimes = []
                guard !times.isEmpty, writer.status == .writing else {
                    writer.cancelWriting()
                    cont.resume(throwing: writer.error ?? CameraError.noFrames)
                    return
                }
                input.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        cont.resume(returning: CameraRecording(url: writer.outputURL, frameTimes: times))
                    } else {
                        cont.resume(throwing: writer.error ?? CameraError.noFrames)
                    }
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let writer, let input, writer.status == .writing, input.isReadyForMoreMediaData else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !sessionStarted {
            // The file's timeline starts at the first frame.
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }
        guard input.append(sampleBuffer) else { return }
        let clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
        frameTimes.append(CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()).seconds)
    }
}
