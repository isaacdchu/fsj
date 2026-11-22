import Foundation

/// The seven jump families, in the order the app shows them.
nonisolated enum JumpFamily: String, CaseIterable, Codable, Identifiable, Sendable {
    case waltz = "W"
    case salchow = "S"
    case toeLoop = "T"
    case loop = "Lo"
    case flip = "F"
    case lutz = "Lu"
    case axel = "A"

    var id: String { rawValue }

    /// Short code shown on buttons, e.g. "Lo".
    var code: String { rawValue }

    var name: String {
        switch self {
        case .waltz: "Waltz"
        case .salchow: "Salchow"
        case .toeLoop: "Toe loop"
        case .loop: "Loop"
        case .flip: "Flip"
        case .lutz: "Lutz"
        case .axel: "Axel"
        }
    }

    /// A waltz jump is always one rotation, so it has no rotation choice.
    var hasRotations: Bool { self != .waltz }
}

/// A family plus a rotation count, e.g. 2Lo. A waltz is always "W".
nonisolated struct JumpCode: Hashable, Codable, Sendable, CustomStringConvertible {
    static let rotationRange = 1...4

    let family: JumpFamily
    let rotations: Int

    init(family: JumpFamily, rotations: Int) {
        self.family = family
        if family.hasRotations {
            self.rotations = min(max(rotations, Self.rotationRange.lowerBound), Self.rotationRange.upperBound)
        } else {
            self.rotations = 1
        }
    }

    var description: String {
        family.hasRotations ? "\(rotations)\(family.code)" : family.code
    }

    /// Spoken form for VoiceOver, e.g. "Double Loop".
    var spokenName: String {
        guard family.hasRotations else { return family.name }
        let prefix = ["Single", "Double", "Triple", "Quad"][rotations - 1]
        return "\(prefix) \(family.name)"
    }
}

/// One saved attempt.
nonisolated struct SavedJump: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var code: JumpCode
    /// Airtime in seconds, takeoff to landing. This is what Stats uses.
    var airtime: Double
    /// Airtime marked on video, in seconds, for jumps saved from the Camera tab.
    var videoAirtime: Double?
    var date: Date

    init(id: UUID = UUID(), code: JumpCode, airtime: Double, videoAirtime: Double? = nil, date: Date) {
        self.id = id
        self.code = code
        self.airtime = airtime
        self.videoAirtime = videoAirtime
        self.date = date
    }
}
