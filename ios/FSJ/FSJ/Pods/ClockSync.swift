import CoreMedia
import Foundation

// The pods and the phone each run their own clock. Before Start and after
// Stop the phone pings each pod over Bluetooth (see `SyncReply` and
// arduino/fsj/protocol.h): it notes its own time when it sends the ping and
// when the reply arrives, and the pod replies with its micros() at the
// moment the ping reached it. The pod's time is matched to the midpoint of
// send and reply, keeping the ping with the shortest round trip. Two such
// matches, one each side of the capture, also give the drift between the
// two crystals. Video frames carry the same phone clock, so pod samples and
// frames end up on one timeline.

/// The phone clock that camera frame timestamps use, in seconds.
nonisolated enum HostClock {
    static func now() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }
}

/// One answered ping.
nonisolated struct ClockSample: Sendable, Equatable {
    /// The pod's clock when the ping arrived (unwrapped micros).
    var podMicros: Int64
    /// The phone's clock at the same moment: midpoint of send and reply.
    var hostSeconds: Double
    /// Reply time minus send time. The match is off by at most half of this.
    var roundTrip: Double

    /// The ping with the shortest round trip is the most accurate.
    static func best(_ samples: [ClockSample]) -> ClockSample? {
        samples.min { $0.roundTrip < $1.roundTrip }
    }
}

/// Converts one pod's micros to phone host seconds.
nonisolated struct PodClock: Sendable, Equatable {
    var podMicros: Int64
    var hostSeconds: Double
    /// Phone seconds per pod second. 1 unless drift could be measured.
    var rate: Double = 1
    /// Worst-case error of the match, in seconds.
    var uncertainty: Double

    func hostTime(podMicros t: Int64) -> Double {
        hostSeconds + Double(t - podMicros) / 1_000_000 * rate
    }

    /// Crystals are within a few hundred ppm, so anything further off than
    /// this is a bad ping, not drift.
    static let maxDrift = 0.001

    /// A clock from the best ping before Start and the best ping after Stop.
    /// Either can be missing.
    static func fit(before: ClockSample?, after: ClockSample?) -> PodClock? {
        switch (before, after) {
        case (nil, nil):
            return nil
        case (let one?, nil), (nil, let one?):
            return PodClock(podMicros: one.podMicros, hostSeconds: one.hostSeconds, uncertainty: one.roundTrip / 2)
        case (let b?, let a?):
            let podSpan = Double(a.podMicros - b.podMicros) / 1_000_000
            let hostSpan = a.hostSeconds - b.hostSeconds
            var rate = 1.0
            if podSpan > 1, abs(hostSpan / podSpan - 1) < maxDrift {
                rate = hostSpan / podSpan
            }
            return PodClock(
                podMicros: b.podMicros,
                hostSeconds: b.hostSeconds,
                rate: rate,
                uncertainty: max(a.roundTrip, b.roundTrip) / 2
            )
        }
    }
}

/// The pods' micros() is 32 bits and wraps every ~71.6 minutes. This turns
/// readings that arrive in roughly increasing order into one 64-bit count.
nonisolated struct MicrosUnwrapper: Sendable {
    private var last: UInt32?
    private var value: Int64 = 0

    mutating func unwrap(_ t: UInt32) -> Int64 {
        if let last {
            value += Int64(Int32(bitPattern: t &- last))
        } else {
            value = Int64(t)
        }
        last = t
        return value
    }
}
