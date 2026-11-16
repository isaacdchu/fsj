import Foundation
import Observation

enum AppTab: Hashable {
    case record, stats, settings
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

    @ObservationIgnored private let estimator = AirtimeEstimator()
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

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

    var bothPodsConnected: Bool { pods.bothConnected }

    func start() {
        guard phase == .idle, bothPodsConnected else { return }
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
