import Foundation

// Swift side of arduino/fsj/protocol.h. Keep the two in sync and check
// `FSJProtocol.version` against FSJ_PROTOCOL_VERSION when the layout changes.
// All multi-byte fields are little-endian.

nonisolated enum FSJProtocol {
    static let version: UInt8 = 3

    static let serviceUUID = "3c820001-3646-49c3-9e01-da24fa4a5faa"
    static let dataUUID = "3c820002-3646-49c3-9e01-da24fa4a5faa"
    static let infoUUID = "3c820003-3646-49c3-9e01-da24fa4a5faa"
    static let controlUUID = "3c820004-3646-49c3-9e01-da24fa4a5faa"
    static let syncUUID = "3c820005-3646-49c3-9e01-da24fa4a5faa"

    static let sampleRateHz: Double = 100
    static let samplesPerPacket = 10
}

/// Written to the control characteristic (one byte). The pod samples and
/// streams only between `start` and `stop`, and stops by itself if the
/// phone disconnects.
nonisolated enum PodCommand: UInt8, Sendable {
    case stop = 0x00
    case start = 0x01
}

/// One IMU reading.
nonisolated struct ImuSample: Sendable, Equatable {
    static let byteCount = 12

    /// milli-g
    var ax: Int16, ay: Int16, az: Int16
    /// 0.1 deg/s
    var gx: Int16, gy: Int16, gz: Int16

    /// Total acceleration in g. About 1 standing still, about 0 in free fall.
    var accelMagnitudeG: Double {
        let x = Double(ax), y = Double(ay), z = Double(az)
        return (x * x + y * y + z * z).squareRoot() / 1000
    }
}

/// Payload of the data characteristic: one notification.
nonisolated struct DataPacket: Sendable, Equatable {
    static let byteCount = 6 + FSJProtocol.samplesPerPacket * ImuSample.byteCount  // 126

    var seq: UInt16
    /// Board micros() of samples[0]; wraps every ~71.6 min.
    var t0Micros: UInt32
    var samples: [ImuSample]

    init(seq: UInt16, t0Micros: UInt32, samples: [ImuSample]) {
        self.seq = seq
        self.t0Micros = t0Micros
        self.samples = samples
    }

    init?(_ data: Data) {
        guard data.count == Self.byteCount else { return nil }
        let b = [UInt8](data)
        seq = LE.u16(b, 0)
        t0Micros = LE.u32(b, 2)
        samples = (0..<FSJProtocol.samplesPerPacket).map { i in
            let o = 6 + i * ImuSample.byteCount
            return ImuSample(
                ax: LE.i16(b, o), ay: LE.i16(b, o + 2), az: LE.i16(b, o + 4),
                gx: LE.i16(b, o + 6), gy: LE.i16(b, o + 8), gz: LE.i16(b, o + 10)
            )
        }
    }

    /// Bytes as the firmware sends them (used by tests).
    var encoded: Data {
        var out = [UInt8]()
        out.reserveCapacity(Self.byteCount)
        LE.put(&out, seq)
        LE.put(&out, t0Micros)
        for s in samples {
            for v in [s.ax, s.ay, s.az, s.gx, s.gy, s.gz] {
                LE.put(&out, UInt16(bitPattern: v))
            }
        }
        return Data(out)
    }
}

/// The pod's answer to a one-byte ping written to the sync characteristic:
/// the ping's id and the pod's micros() when the ping arrived.
nonisolated struct SyncReply: Sendable, Equatable {
    static let byteCount = 5

    var id: UInt8
    var tMicros: UInt32

    init(id: UInt8, tMicros: UInt32) {
        self.id = id
        self.tMicros = tMicros
    }

    init?(_ data: Data) {
        guard data.count == Self.byteCount else { return nil }
        let b = [UInt8](data)
        id = b[0]
        tMicros = LE.u32(b, 1)
    }

    /// Bytes as the firmware sends them (used by tests).
    var encoded: Data {
        var out = [id]
        LE.put(&out, tMicros)
        return Data(out)
    }
}

/// Payload of the info characteristic.
nonisolated struct InfoPacket: Sendable, Equatable {
    static let byteCount = 5

    var version: UInt8
    var side: PodSide?
    var sampleRateHz: UInt16
    var samplesPerPacket: UInt8

    init?(_ data: Data) {
        guard data.count == Self.byteCount else { return nil }
        let b = [UInt8](data)
        version = b[0]
        side = b[1] == 0 ? .left : (b[1] == 1 ? .right : nil)
        sampleRateHz = LE.u16(b, 2)
        samplesPerPacket = b[4]
    }
}

/// Little-endian helpers.
nonisolated enum LE {
    static func u16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | UInt16(b[o + 1]) << 8
    }

    static func i16(_ b: [UInt8], _ o: Int) -> Int16 {
        Int16(bitPattern: u16(b, o))
    }

    static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    static func put(_ out: inout [UInt8], _ v: UInt16) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8(v >> 8))
    }

    static func put(_ out: inout [UInt8], _ v: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            out.append(UInt8((v >> UInt32(shift)) & 0xFF))
        }
    }
}
