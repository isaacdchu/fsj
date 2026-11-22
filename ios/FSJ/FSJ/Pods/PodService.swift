import Foundation

/// Which skate a pod is on.
nonisolated enum PodSide: String, CaseIterable, Identifiable, Sendable {
    case left = "L"
    case right = "R"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .left: "Left skate pod"
        case .right: "Right skate pod"
        }
    }

    /// The name the firmware advertises (`FSJ-L` / `FSJ-R`).
    var advertisedName: String { "FSJ-\(rawValue)" }

    init?(advertisedName: String) {
        guard let side = PodSide.allCases.first(where: { $0.advertisedName == advertisedName }) else { return nil }
        self = side
    }
}

nonisolated enum PodConnection: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
}

nonisolated struct PodStatus: Sendable, Equatable {
    var connection: PodConnection = .disconnected
    var batteryPercent: Int?
}

/// Everything both pods streamed between Start and Stop.
nonisolated struct PodCapture: Sendable {
    var sampleRateHz: Double
    var samples: [PodSide: [ImuSample]]
    /// Each sample's time on the pod's own clock (micros), same order as `samples`.
    var times: [PodSide: [Int64]] = [:]
    /// How each pod's clock maps to the phone's. Missing if the pod could
    /// not be synced (for example older firmware).
    var clocks: [PodSide: PodClock] = [:]

    /// Each sample's time on the phone's host clock, if this pod was synced.
    func hostTimes(_ side: PodSide) -> [Double]? {
        guard let clock = clocks[side], let times = times[side],
              times.count == samples[side]?.count else { return nil }
        return times.map { clock.hostTime(podMicros: $0) }
    }
}

nonisolated enum PodServiceError: LocalizedError, Sendable {
    case notConnected
    case bluetoothUnavailable
    case podDidNotRespond(PodSide)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Both pods need to be connected."
        case .bluetoothUnavailable: "Bluetooth is off or not allowed for this app."
        case .podDidNotRespond(let side): "The \(side.name.lowercased()) did not respond."
        }
    }
}

/// The app's only view of the pods. Start and Stop are commands sent to
/// the pods; the pods stream IMU data back, and the phone works out the
/// airtime from it (see `AirtimeEstimator`).
///
/// Implementations: `BluetoothPodService` (CoreBluetooth, matches
/// `arduino/fsj/protocol.h`) and `SimulatedPodService` (no hardware).
/// Swap or replace one without touching the views.
protocol PodService: AnyObject {
    func status(of side: PodSide) -> PodStatus
    func connect(_ side: PodSide)
    func disconnect(_ side: PodSide)

    /// Tell both pods to start streaming.
    func startStreaming() async throws
    /// Tell both pods to stop, and return what they sent.
    func stopStreaming() async throws -> PodCapture
}

extension PodService {
    var bothConnected: Bool {
        PodSide.allCases.allSatisfy { status(of: $0).connection == .connected }
    }
}
