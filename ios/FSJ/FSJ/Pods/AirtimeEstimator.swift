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
        guard sampleRateHz > 0 else { return nil }
        var best = 0
        var runStart: Int?
        var lastLow = 0

        for (i, s) in samples.enumerated() {
            if s.accelMagnitudeG < freeFallThresholdG {
                if runStart == nil { runStart = i }
                lastLow = i
            } else if let start = runStart, i - lastLow > maxGapSamples {
                best = max(best, lastLow - start + 1)
                runStart = nil
            }
        }
        if let start = runStart {
            best = max(best, lastLow - start + 1)
        }

        let seconds = Double(best) / sampleRateHz
        return plausibleAirtime.contains(seconds) ? seconds : nil
    }
}
