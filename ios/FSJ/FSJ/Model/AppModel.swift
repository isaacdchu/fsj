import Foundation
import Observation

enum AppTab: Hashable {
    case record, camera, stats, settings
}

enum RecordPhase: Equatable {
    case idle
    /// Pods are streaming.
    case recording(since: Date)
    /// Pods stopped; waiting for the last data and working out the airtime.
    case receiving
    /// Airtime known; the skater tags the jump, then saves or discards it.
    case review(airtime: Double)
}

enum CameraPhase: Equatable {
    case idle
    /// Video recording and pods streaming.
    case filming(since: Date)
    /// Both stopped; finishing the video file and the pod data.
    case receiving
    /// Step through the clip and mark takeoff and landing.
    case mark(clip: VideoClip, podAirtime: Double?)
}

/// A short message in the hint area of the Record screen.
struct RecordNotice: Equatable {
    enum Kind { case saved, problem }
    var kind: Kind
    var text: String
}

@Observable
final class AppModel {
    let store: JumpStore
    let pods: any PodService

    var tab: AppTab = .record
    var phase: RecordPhase = .idle
    var notice: RecordNotice?
    /// Rotation choice on the tag screen. Kept between jumps.
    var tagRotations = 2

    let camera = CameraRecorder()
    var cameraPhase: CameraPhase = .idle
    var cameraNotice: RecordNotice?
    /// Set when saving a marked clip fails; shown on the mark screen.
    var cameraSaveError: String?

    @ObservationIgnored private let estimator = AirtimeEstimator()
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var cameraNoticeTask: Task<Void, Never>?

    init(store: JumpStore, pods: any PodService) {
        self.store = store
        self.pods = pods
    }

    /// The app as it runs on a phone. The simulator, or the launch argument
    /// `-simulatedPods`, uses made-up pods instead of Bluetooth.
    static func live() -> AppModel {
        let pods: any PodService
        #if targetEnvironment(simulator)
        pods = SimulatedPodService()
        #else
        if ProcessInfo.processInfo.arguments.contains("-simulatedPods") {
            pods = SimulatedPodService()
        } else {
            pods = BluetoothPodService()
        }
        #endif
        return AppModel(store: JumpStore(), pods: pods)
    }

    static func preview(phase: RecordPhase = .idle, connected: Bool = true) -> AppModel {
        let model = AppModel(store: .preview(), pods: SimulatedPodService(startConnected: connected))
        model.phase = phase
        return model
    }

    // MARK: Recording

    var isStreaming: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isFilming: Bool {
        if case .filming = cameraPhase { return true }
        return false
    }

    /// Pods are streaming, from either the Record or the Camera tab.
    var podsStreaming: Bool { isStreaming || isFilming }

    var bothPodsConnected: Bool { pods.bothConnected }

    func start() {
        guard phase == .idle, cameraPhase == .idle, bothPodsConnected else { return }
        clearNotice()
        phase = .recording(since: .now)
        Task {
            do {
                try await pods.startStreaming()
            } catch {
                if isStreaming { phase = .idle }
                show(.problem, error.localizedDescription)
            }
        }
    }

    func stop() {
        guard isStreaming else { return }
        phase = .receiving
        Task {
            do {
                let capture = try await pods.stopStreaming()
                if let airtime = estimator.airtime(capture) {
                    phase = .review(airtime: airtime)
                } else {
                    phase = .idle
                    show(.problem, "No jump found in the pod data.")
                }
            } catch {
                phase = .idle
                show(.problem, error.localizedDescription)
            }
        }
    }

    func save(_ code: JumpCode) {
        guard case .review(let airtime) = phase else { return }
        store.add(code, airtime: airtime)
        phase = .idle
        show(.saved, "Saved \(code), \(Format.ms(airtime)) ms")
    }

    func discard() {
        phase = .idle
    }

    // MARK: Camera

    /// Record starts the video and both pods together.
    func cameraRecord() {
        guard cameraPhase == .idle, phase == .idle, bothPodsConnected else { return }
        clearCameraNotice()
        cameraPhase = .filming(since: .now)
        Task {
            do {
                try await camera.startRecording()
            } catch {
                cameraPhase = .idle
                showCamera(.problem, error.localizedDescription)
                return
            }
            do {
                try await pods.startStreaming()
            } catch {
                if let clip = try? await camera.stopRecording() { camera.discard(clip) }
                cameraPhase = .idle
                showCamera(.problem, error.localizedDescription)
            }
        }
    }

    /// Stop ends the video and both pods.
    func cameraStop() {
        guard isFilming else { return }
        cameraPhase = .receiving
        Task {
            let clip: VideoClip
            do {
                clip = try await camera.stopRecording()
            } catch {
                _ = try? await pods.stopStreaming()
                cameraPhase = .idle
                showCamera(.problem, error.localizedDescription)
                return
            }
            let capture = try? await pods.stopStreaming()
            let podAirtime = capture.flatMap { estimator.airtime($0) }
            cameraSaveError = nil
            cameraPhase = .mark(clip: clip, podAirtime: podAirtime)
        }
    }

    /// Save the clip to Photos. `airtime` is the marked takeoff-to-landing time in seconds.
    func cameraSave(airtime: Double) {
        guard case .mark(let clip, _) = cameraPhase else { return }
        cameraSaveError = nil
        Task {
            do {
                try await camera.saveToPhotos(clip)
                cameraPhase = .idle
                showCamera(.saved, "Video saved, airtime \(Format.ms(airtime)) ms")
            } catch {
                cameraSaveError = error.localizedDescription
            }
        }
    }

    func cameraDiscard() {
        guard case .mark(let clip, _) = cameraPhase else { return }
        camera.discard(clip)
        cameraSaveError = nil
        cameraPhase = .idle
    }

    private func showCamera(_ kind: RecordNotice.Kind, _ text: String) {
        cameraNotice = RecordNotice(kind: kind, text: text)
        cameraNoticeTask?.cancel()
        let shown = cameraNotice
        cameraNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(kind == .saved ? 2.6 : 4))
            guard !Task.isCancelled, let self, self.cameraNotice == shown else { return }
            self.cameraNotice = nil
        }
    }

    private func clearCameraNotice() {
        cameraNoticeTask?.cancel()
        cameraNotice = nil
    }

    // MARK: Notices

    private func show(_ kind: RecordNotice.Kind, _ text: String) {
        notice = RecordNotice(kind: kind, text: text)
        noticeTask?.cancel()
        let shown = notice
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(kind == .saved ? 2.6 : 4))
            guard !Task.isCancelled, let self, self.notice == shown else { return }
            self.notice = nil
        }
    }

    private func clearNotice() {
        noticeTask?.cancel()
        notice = nil
    }
}
