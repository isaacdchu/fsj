import Foundation
import Observation

/// Saved jumps, kept as a JSON file in Application Support.
@Observable
final class JumpStore {
    /// Oldest first.
    private(set) var jumps: [SavedJump]

    @ObservationIgnored private let fileURL: URL?

    /// Pass nil for an in-memory store (previews and tests).
    init(fileURL: URL? = JumpStore.defaultFileURL, jumps: [SavedJump]? = nil) {
        self.fileURL = fileURL
        self.jumps = jumps ?? Self.load(from: fileURL)
    }

    static var defaultFileURL: URL? {
        let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir?.appendingPathComponent("jumps.json")
    }

    // MARK: Changes

    func add(_ code: JumpCode, airtime: Double, videoAirtime: Double? = nil, date: Date = .now) {
        jumps.append(SavedJump(code: code, airtime: airtime, videoAirtime: videoAirtime, date: date))
        save()
    }

    func clearAll() {
        jumps.removeAll()
        save()
    }

    // MARK: Queries

    /// Newest first.
    func recent(_ limit: Int) -> [SavedJump] {
        Array(jumps.suffix(limit).reversed())
    }

    /// Oldest first.
    func jumps(for code: JumpCode) -> [SavedJump] {
        jumps.filter { $0.code == code }
    }

    func count(in family: JumpFamily) -> Int {
        jumps.reduce(0) { $0 + ($1.code.family == family ? 1 : 0) }
    }

    /// Codes in this family that have at least one attempt, fewest rotations first.
    func codesWithData(in family: JumpFamily) -> [JumpCode] {
        let present = Set(jumps.lazy.filter { $0.code.family == family }.map(\.code))
        return present.sorted { $0.rotations < $1.rotations }
    }

    // MARK: Persistence

    private static func load(from url: URL?) -> [SavedJump] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SavedJump].self, from: data)) ?? []
    }

    private func save() {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(jumps)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("JumpStore: save failed: \(error)")
        }
    }
}

extension JumpStore {
    /// Sample data matching the mockup, for previews.
    static func preview() -> JumpStore {
        let samples: [(String, [Double])] = [
            ("W", [0.36, 0.38, 0.35]),
            ("1S", [0.42, 0.44]),
            ("1A", [0.47, 0.50, 0.48, 0.52, 0.49, 0.51]),
            ("2S", [0.51, 0.53, 0.50, 0.54, 0.52]),
            ("2T", [0.54, 0.52, 0.56, 0.53, 0.55, 0.57, 0.54]),
            ("2Lo", [0.53, 0.51, 0.55, 0.52]),
            ("2F", [0.55, 0.57, 0.54, 0.56]),
            ("2Lu", [0.56, 0.58, 0.55]),
            ("2A", [0.58, 0.60, 0.57]),
        ]
        var jumps: [SavedJump] = []
        var date = Date.now.addingTimeInterval(-2 * 24 * 3600)
        for (text, times) in samples {
            let rotations = Int(String(text.prefix(1))) ?? 1
            let familyCode = text.drop { $0.isNumber }
            let family = JumpFamily(rawValue: String(familyCode)) ?? .waltz
            for t in times {
                jumps.append(SavedJump(code: JumpCode(family: family, rotations: rotations), airtime: t, date: date))
                date.addTimeInterval(180)
            }
        }
        return JumpStore(fileURL: nil, jumps: jumps)
    }
}
