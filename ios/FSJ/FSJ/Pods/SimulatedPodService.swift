import Foundation
import Observation

/// Stand-in pods for the simulator and for trying the app without hardware.
/// Stop returns made-up IMU data with one jump in it, so the real airtime
/// estimator runs on it. Each pod has its own made-up clock, synced to the
/// phone's like the real pods; when the simulated camera is filming, the
/// jump lands where it does in the made-up video, give or take a few ms.
@Observable
final class SimulatedPodService: PodService {
    private var statuses: [PodSide: PodStatus]
    @ObservationIgnored private var streamStart: Date?
    @ObservationIgnored private var streamStartHost: Double = 0
    /// Phone time when each made-up pod clock read zero.
    private let podBoot: [PodSide: Double] = [
        .left: HostClock.now() - Double.random(in: 60...600),
        .right: HostClock.now() - Double.random(in: 60...600),
    ]

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
        streamStartHost = HostClock.now()
    }

    func stopStreaming() async throws -> PodCapture {
        let elapsed = streamStart.map { Date.now.timeIntervalSince($0) } ?? 0
        streamStart = nil
        // Stand-in for the radio and the phone crunching the data.
        try await Task.sleep(for: .seconds(1.1))

        let rate = FSJProtocol.sampleRateHz
        var total = Int(min(max(elapsed, 2), 60) * rate)
        var air = Int(Double.random(in: 0.44...0.60) * rate)
        var freeFall = max(16, (total - air) / 2)
        if let videoStart = SimulatedScene.takeVideoStart() {
            // Match the made-up video: in the air from frame 300 to 428 at 240 fps.
            let takeoffHost = videoStart + Double(VideoClip.simulatedTakeoff) / 240 + 0.004
            let videoAir = Double(VideoClip.simulatedLanding - VideoClip.simulatedTakeoff) / 240
            freeFall = max(16, Int(((takeoffHost - streamStartHost) * rate).rounded()))
            air = Int(((videoAir + Double.random(in: -0.008...0.008)) * rate).rounded())
            total = max(total, freeFall + air + 60)
        }

        var samples: [PodSide: [ImuSample]] = [:]
        var times: [PodSide: [Int64]] = [:]
        var clocks: [PodSide: PodClock] = [:]
        for side in PodSide.allCases {
            let jitter = Int.random(in: -1...1)
            samples[side] = Self.jump(total: total, freeFall: freeFall, air: air + jitter)
            let boot = podBoot[side] ?? 0
            let firstMicros = Int64(((streamStartHost - boot) * 1_000_000).rounded())
            let step = Int64((1_000_000 / rate).rounded())
            times[side] = (0..<total).map { firstMicros + Int64($0) * step }
            clocks[side] = PodClock(podMicros: 0, hostSeconds: boot, uncertainty: 0.003)
        }
        return PodCapture(sampleRateHz: rate, samples: samples, times: times, clocks: clocks)
    }

    /// Glide, then a takeoff spike, free fall, and a landing spike.
    private static func jump(total: Int, freeFall: Int, air: Int) -> [ImuSample] {
        func n(_ amp: Int16) -> Int16 { Int16.random(in: -amp...amp) }
        let takeoff = freeFall - 6
        let landing = freeFall + air
        return (0..<total).map { i in
            switch i {
            case takeoff..<freeFall:
                ImuSample(ax: n(400), ay: n(400), az: 2500 + n(400), gx: n(800), gy: n(800), gz: 8000)
            case freeFall..<landing:
                ImuSample(ax: n(60), ay: n(60), az: n(60), gx: n(300), gy: n(300), gz: 16000 + n(500))
            case landing..<(landing + 4):
                ImuSample(ax: n(1000), ay: n(1000), az: 4000 + n(1000), gx: n(1500), gy: n(1500), gz: 5000)
            default:
                ImuSample(ax: n(80), ay: n(80), az: 1000 + n(60), gx: n(300), gy: n(300), gz: n(400))
            }
        }
    }
}

/// Lets the made-up camera and made-up pods agree on where the jump is.
enum SimulatedScene {
    private static var videoStart: Double?

    /// Called by the simulated camera when it starts "filming".
    static func videoStarted(at host: Double) {
        videoStart = host
    }

    /// Read once by the simulated pods when they stop.
    static func takeVideoStart() -> Double? {
        defer { videoStart = nil }
        return videoStart
    }
}
