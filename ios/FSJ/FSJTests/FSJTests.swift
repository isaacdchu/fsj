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
