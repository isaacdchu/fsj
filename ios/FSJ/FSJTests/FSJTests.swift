//
//  FSJTests.swift
//  FSJTests
//

import Foundation
import Testing
@testable import FSJ

@MainActor
struct JumpCodeTests {
    @Test func codesReadLikeTheMockup() {
        #expect(JumpCode(family: .loop, rotations: 2).description == "2Lo")
        #expect(JumpCode(family: .axel, rotations: 3).description == "3A")
        #expect(JumpCode(family: .toeLoop, rotations: 1).spokenName == "Single Toe loop")
    }

    @Test func waltzIsAlwaysOneRotation() {
        let w = JumpCode(family: .waltz, rotations: 3)
        #expect(w.rotations == 1)
        #expect(w.description == "W")
    }

    @Test func rotationsAreClamped() {
        #expect(JumpCode(family: .lutz, rotations: 7).rotations == 4)
        #expect(JumpCode(family: .lutz, rotations: 0).rotations == 1)
    }
}

@MainActor
struct JumpStatsTests {
    @Test func emptyHasNoStats() {
        #expect(JumpStats([]) == nil)
    }

    @Test func singleAttempt() throws {
        let s = try #require(JumpStats([0.5]))
        #expect(s.count == 1)
        #expect(s.mean == 0.5)
        #expect(s.median == 0.5)
        #expect(s.standardDeviation == nil)
    }

    @Test func knownValues() throws {
        let s = try #require(JumpStats([0.53, 0.51, 0.55, 0.52]))
        #expect(s.count == 4)
        #expect(abs(s.mean - 0.5275) < 1e-9)
        #expect(abs(s.median - 0.525) < 1e-9)
        #expect(s.min == 0.51)
        #expect(s.max == 0.55)
        // sample SD: sqrt(sum((x - mean)^2) / (n - 1))
        #expect(abs((s.standardDeviation ?? 0) - 0.0170782512765993) < 1e-9)
    }
}

@MainActor
struct PodProtocolTests {
    @Test func dataPacketRoundTrip() throws {
        let samples = (0..<10).map { i in
            ImuSample(ax: Int16(i), ay: -1000, az: 1000, gx: -32768, gy: 32767, gz: Int16(-i))
        }
        let packet = DataPacket(seq: 0xBEEF, t0Micros: 0xDEADBEEF, samples: samples)
        let bytes = packet.encoded
        #expect(bytes.count == 126)
        #expect(bytes.first == 0xEF)  // little-endian seq
        #expect(DataPacket(bytes) == packet)
    }

    @Test func wrongSizeIsRejected() {
        #expect(DataPacket(Data(count: 125)) == nil)
        #expect(InfoPacket(Data(count: 4)) == nil)
    }

    @Test func controlCommandsMatchFirmware() {
        // CMD_STOP / CMD_START in arduino/fsj/protocol.h
        #expect(PodCommand.stop.rawValue == 0x00)
        #expect(PodCommand.start.rawValue == 0x01)
    }

    @Test func infoPacket() throws {
        let info = try #require(InfoPacket(Data([2, 1, 100, 0, 10])))
        #expect(info.version == FSJProtocol.version)
        #expect(info.side == .right)
        #expect(info.sampleRateHz == 100)
        #expect(info.samplesPerPacket == 10)
    }
}

@MainActor
struct AirtimeEstimatorTests {
    private func glide(_ n: Int) -> [ImuSample] {
        Array(repeating: ImuSample(ax: 20, ay: -30, az: 1010, gx: 0, gy: 0, gz: 0), count: n)
    }

    private func air(_ n: Int) -> [ImuSample] {
        Array(repeating: ImuSample(ax: 30, ay: 10, az: -40, gx: 0, gy: 0, gz: 16000), count: n)
    }

    @Test func freeFallStretchIsTheAirtime() throws {
        let samples = glide(100) + air(52) + glide(100)
        let t = try #require(AirtimeEstimator().airtime(samples: samples, sampleRateHz: 100))
        #expect(abs(t - 0.52) < 1e-9)
    }

    @Test func shortNoiseInsideFlightIsIgnored() throws {
        let samples = glide(50) + air(20) + glide(1) + air(29) + glide(50)
        let t = try #require(AirtimeEstimator().airtime(samples: samples, sampleRateHz: 100))
        #expect(abs(t - 0.50) < 1e-9)
    }

    @Test func noJumpGivesNil() {
        #expect(AirtimeEstimator().airtime(samples: glide(300), sampleRateHz: 100) == nil)
    }

    @Test func bothPodsAreAveraged() throws {
        let capture = PodCapture(sampleRateHz: 100, samples: [
            .left: glide(10) + air(50) + glide(10),
            .right: glide(10) + air(54) + glide(10),
        ])
        let t = try #require(AirtimeEstimator().airtime(capture))
        #expect(abs(t - 0.52) < 1e-9)
    }
}

@MainActor
struct JumpStoreTests {
    @Test func savesAndReloads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fsj-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = JumpStore(fileURL: url)
        store.add(JumpCode(family: .loop, rotations: 2), airtime: 0.534)
        store.add(JumpCode(family: .waltz, rotations: 1), airtime: 0.36)

        let reloaded = JumpStore(fileURL: url)
        #expect(reloaded.jumps.count == 2)
        #expect(reloaded.jumps.first?.code.description == "2Lo")
        #expect(reloaded.codesWithData(in: .loop).map(\.description) == ["2Lo"])
        #expect(reloaded.recent(3).first?.code.description == "W")

        reloaded.clearAll()
        #expect(JumpStore(fileURL: url).jumps.isEmpty)
    }
}

@MainActor
struct FormatTests {
    @Test func airtimesShowInMilliseconds() {
        #expect(Format.ms(0.534) == "534")
        #expect(Format.ms(0.5) == "500")
        #expect(Format.msTenths(0.0170782512765993) == "17.1")
    }
}

@MainActor
struct VideoClipTests {
    @Test func framesConvertToMilliseconds() {
        let clip = VideoClip(url: nil, fps: 240, frameCount: 768)
        #expect(clip.lastFrame == 767)
        #expect(Format.ms(clip.ms(at: 128) / 1000) == "533")
    }
}

@MainActor
struct ClockSyncTests {
    @Test func syncReplyMatchesFirmware() throws {
        // struct SyncReply { uint8_t id; uint32_t t_us; } in arduino/fsj/protocol.h
        let reply = try #require(SyncReply(Data([7, 0xEF, 0xBE, 0xAD, 0xDE])))
        #expect(reply.id == 7)
        #expect(reply.tMicros == 0xDEADBEEF)
        #expect(reply.encoded.count == SyncReply.byteCount)
        #expect(SyncReply(reply.encoded) == reply)
        #expect(SyncReply(Data(count: 4)) == nil)
        #expect(FSJProtocol.version == 3)
    }

    @Test func microsUnwrapAcrossOverflow() {
        var u = MicrosUnwrapper()
        #expect(u.unwrap(UInt32.max - 999) == Int64(UInt32.max) - 999)
        #expect(u.unwrap(500) == Int64(UInt32.max) + 501)
        // A slightly older reading (packets and pings interleave) goes back, not forward.
        #expect(u.unwrap(400) == Int64(UInt32.max) + 401)
    }

    @Test func shortestRoundTripWins() {
        let samples = [
            ClockSample(podMicros: 1, hostSeconds: 10, roundTrip: 0.040),
            ClockSample(podMicros: 2, hostSeconds: 11, roundTrip: 0.018),
            ClockSample(podMicros: 3, hostSeconds: 12, roundTrip: 0.030),
        ]
        #expect(ClockSample.best(samples)?.podMicros == 2)
        #expect(ClockSample.best([]) == nil)
    }

    @Test func clockFitsOffsetAndDrift() throws {
        // Pod clock runs 100 ppm slow relative to the phone.
        let before = ClockSample(podMicros: 5_000_000, hostSeconds: 1000, roundTrip: 0.02)
        let after = ClockSample(podMicros: 15_000_000, hostSeconds: 1010.001, roundTrip: 0.03)
        let clock = try #require(PodClock.fit(before: before, after: after))
        #expect(abs(clock.rate - 1.0001) < 1e-9)
        #expect(abs(clock.hostTime(podMicros: 10_000_000) - 1005.0005) < 1e-6)
        #expect(abs(clock.uncertainty - 0.015) < 1e-12)
    }

    @Test func implausibleDriftIsIgnored() throws {
        let before = ClockSample(podMicros: 0, hostSeconds: 0, roundTrip: 0.02)
        let after = ClockSample(podMicros: 2_000_000, hostSeconds: 2.1, roundTrip: 0.02)
        let clock = try #require(PodClock.fit(before: before, after: after))
        #expect(clock.rate == 1)
        #expect(PodClock.fit(before: nil, after: after)?.hostSeconds == 2.1)
        #expect(PodClock.fit(before: nil, after: nil) == nil)
    }

    @Test func hostTimeToVideoFrame() {
        // 240 fps clip with one dropped frame after frame 9.
        var times = (0..<10).map { 100 + Double($0) / 240 }
        times += (11..<20).map { 100 + Double($0) / 240 }
        let clip = VideoClip(url: nil, fps: 240, frameTimes: times)
        #expect(clip.lastFrame == 18)
        #expect(abs(clip.framePosition(ofHost: 100 + 3.5 / 240) - 3.5) < 1e-9)
        // Frame 10 is the one captured at 11/240.
        #expect(abs(clip.framePosition(ofHost: 100 + 11 / 240.0) - 10) < 1e-9)
        #expect(abs(clip.framePosition(ofHost: 100 - 2 / 240.0) - -2) < 1e-9)
        #expect(Format.ms(clip.ms(at: 10) / 1000) == "46")
    }

    @Test func syncedCaptureLinesUpTheJump() throws {
        let still = ImuSample(ax: 0, ay: 0, az: 1000, gx: 0, gy: 0, gz: 0)
        let air = ImuSample(ax: 0, ay: 0, az: 0, gx: 0, gy: 0, gz: 0)
        let samples = Array(repeating: still, count: 100) + Array(repeating: air, count: 50) + Array(repeating: still, count: 100)
        // Pod clock reads 2 s when the phone reads 500 s.
        let times = samples.indices.map { 2_000_000 + Int64($0) * 10_000 }
        let capture = PodCapture(
            sampleRateHz: 100,
            samples: [.left: samples],
            times: [.left: times],
            clocks: [.left: PodClock(podMicros: 2_000_000, hostSeconds: 500, uncertainty: 0.004)]
        )
        let pods = try #require(AirtimeEstimator().synced(capture))
        #expect(pods.traces.count == 1)
        let takeoff = try #require(pods.takeoff), landing = try #require(pods.landing)
        #expect(abs(takeoff - 500.995) < 1e-9)
        #expect(abs(landing - 501.495) < 1e-9)
        #expect(pods.uncertainty == 0.004)
        #expect(AirtimeEstimator().synced(PodCapture(sampleRateHz: 100, samples: [.left: samples])) == nil)
    }
}
