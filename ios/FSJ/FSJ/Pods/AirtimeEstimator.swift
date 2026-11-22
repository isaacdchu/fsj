import Foundation

/// Works out airtime from what the pods streamed.
///
/// First pass: while the skater is in the air the accelerometer reads close
/// to 0 g (free fall). The airtime is the longest stretch of low-g samples,
/// allowing a couple of noisy samples inside it. Each pod is measured on its
/// own and the results are averaged. Tune this once real IMU data exists.
nonisolated struct AirtimeEstimator: Sendable {
    var freeFallThresholdG = 0.35
    /// Samples above the threshold allowed inside one free-fall stretch.
    var maxGapSamples = 2
    var plausibleAirtime: ClosedRange<Double> = 0.15...1.5

    func airtime(_ capture: PodCapture) -> Double? {
        let perPod = PodSide.allCases.compactMap { side in
            capture.samples[side].flatMap { airtime(samples: $0, sampleRateHz: capture.sampleRateHz) }
        }
        guard !perPod.isEmpty else { return nil }
        return perPod.reduce(0, +) / Double(perPod.count)
    }

    func airtime(samples: [ImuSample], sampleRateHz: Double) -> Double? {
        flight(samples: samples, sampleRateHz: sampleRateHz).map { Double($0.count) / sampleRateHz }
    }

    /// Indices of the first and last free-fall sample of the jump, or nil if
    /// there is no stretch of plausible length.
    func flight(samples: [ImuSample], sampleRateHz: Double) -> ClosedRange<Int>? {
        guard sampleRateHz > 0 else { return nil }
        var best: ClosedRange<Int>?
        var runStart: Int?
        var lastLow = 0

        func close(_ start: Int) {
            if lastLow - start + 1 > best?.count ?? 0 { best = start...lastLow }
        }

        for (i, s) in samples.enumerated() {
            if s.accelMagnitudeG < freeFallThresholdG {
                if runStart == nil { runStart = i }
                lastLow = i
            } else if let start = runStart, i - lastLow > maxGapSamples {
                close(start)
                runStart = nil
            }
        }
        if let start = runStart { close(start) }

        guard let best, plausibleAirtime.contains(Double(best.count) / sampleRateHz) else { return nil }
        return best
    }

    /// Pod data placed on the phone's clock, for lining up with video.
    /// Nil unless at least one pod was synced.
    func synced(_ capture: PodCapture) -> SyncedPods? {
        let rate = capture.sampleRateHz
        let traces: [PodTrace] = PodSide.allCases.compactMap { side in
            guard let samples = capture.samples[side], let hostTimes = capture.hostTimes(side),
                  let clock = capture.clocks[side] else { return nil }
            // A sample is the middle of its 1/rate slot, so the flight runs
            // half a slot either side of the first and last low-g samples.
            let flight = self.flight(samples: samples, sampleRateHz: rate).map {
                (hostTimes[$0.lowerBound] - 0.5 / rate)...(hostTimes[$0.upperBound] + 0.5 / rate)
            }
            return PodTrace(
                side: side,
                hostTimes: hostTimes,
                g: samples.map(\.accelMagnitudeG),
                flight: flight,
                uncertainty: clock.uncertainty
            )
        }
        return traces.isEmpty ? nil : SyncedPods(traces: traces)
    }
}

/// One pod's acceleration on the phone's clock.
nonisolated struct PodTrace: Sendable, Equatable {
    var side: PodSide
    var hostTimes: [Double]
    /// Total acceleration in g per sample.
    var g: [Double]
    /// Takeoff to landing on the phone's clock, if a jump was found.
    var flight: ClosedRange<Double>?
    /// Clock-match error, seconds.
    var uncertainty: Double
}

/// Both pods' data on the phone's clock.
nonisolated struct SyncedPods: Sendable, Equatable {
    var traces: [PodTrace]

    private var flights: [ClosedRange<Double>] { traces.compactMap(\.flight) }

    /// Mean takeoff across the pods that found the jump.
    var takeoff: Double? {
        flights.isEmpty ? nil : flights.map(\.lowerBound).reduce(0, +) / Double(flights.count)
    }

    var landing: Double? {
        flights.isEmpty ? nil : flights.map(\.upperBound).reduce(0, +) / Double(flights.count)
    }

    /// Worst clock-match error across the pods, seconds.
    var uncertainty: Double { traces.map(\.uncertainty).max() ?? 0 }
}
