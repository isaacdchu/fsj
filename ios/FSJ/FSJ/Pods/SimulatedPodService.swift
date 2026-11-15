import Foundation
import Observation

/// Stand-in pods for the simulator and for trying the app without hardware.
/// Stop returns made-up IMU data with one jump in it, so the real airtime
/// estimator runs on it.
@Observable
final class SimulatedPodService: PodService {
    private var statuses: [PodSide: PodStatus]
    @ObservationIgnored private var streamStart: Date?

    init(startConnected: Bool = false) {
        let connection: PodConnection = startConnected ? .connected : .disconnected
        statuses = [
            .left: PodStatus(connection: connection, batteryPercent: 82),
            .right: PodStatus(connection: connection, batteryPercent: 79),
        ]
    }

    func status(of side: PodSide) -> PodStatus {
        statuses[side] ?? PodStatus()
    }

    func connect(_ side: PodSide) {
        guard status(of: side).connection == .disconnected else { return }
        statuses[side, default: PodStatus()].connection = .connecting
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.3))
            guard let self, self.status(of: side).connection == .connecting else { return }
            self.statuses[side, default: PodStatus()].connection = .connected
        }
    }

    func disconnect(_ side: PodSide) {
        statuses[side, default: PodStatus()].connection = .disconnected
    }

    func startStreaming() async throws {
        guard bothConnected else { throw PodServiceError.notConnected }
        streamStart = .now
    }

    func stopStreaming() async throws -> PodCapture {
        let elapsed = streamStart.map { Date.now.timeIntervalSince($0) } ?? 0
        streamStart = nil
        // Stand-in for the radio and the phone crunching the data.
        try await Task.sleep(for: .seconds(1.1))

        let rate = FSJProtocol.sampleRateHz
        let total = Int(min(max(elapsed, 2), 60) * rate)
        let air = Int(Double.random(in: 0.44...0.60) * rate)
        let takeoff = max(10, (total - air) / 2)

        var samples: [PodSide: [ImuSample]] = [:]
        for side in PodSide.allCases {
            let jitter = Int.random(in: -1...1)
            samples[side] = Self.jump(total: total, takeoff: takeoff, air: air + jitter)
        }
        return PodCapture(sampleRateHz: rate, samples: samples)
    }

    /// Glide, then a takeoff spike, free fall, and a landing spike.
    private static func jump(total: Int, takeoff: Int, air: Int) -> [ImuSample] {
        func n(_ amp: Int16) -> Int16 { Int16.random(in: -amp...amp) }
        let landing = takeoff + 6 + air
        return (0..<total).map { i in
            switch i {
            case takeoff..<(takeoff + 6):
                ImuSample(ax: n(400), ay: n(400), az: 2500 + n(400), gx: n(800), gy: n(800), gz: 8000)
            case (takeoff + 6)..<landing:
                ImuSample(ax: n(60), ay: n(60), az: n(60), gx: n(300), gy: n(300), gz: 16000 + n(500))
            case landing..<(landing + 4):
                ImuSample(ax: n(1000), ay: n(1000), az: 4000 + n(1000), gx: n(1500), gy: n(1500), gz: 5000)
            default:
                ImuSample(ax: n(80), ay: n(80), az: 1000 + n(60), gx: n(300), gy: n(300), gz: n(400))
            }
        }
    }
}
