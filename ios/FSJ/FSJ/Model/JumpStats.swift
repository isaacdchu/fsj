import Foundation

/// Summary statistics for the airtimes of one jump code.
nonisolated struct JumpStats: Equatable, Sendable {
    let count: Int
    let mean: Double
    /// Sample standard deviation (n - 1). Nil with fewer than two attempts.
    let standardDeviation: Double?
    let median: Double
    let min: Double
    let max: Double

    init?(_ values: [Double]) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let n = values.count
        let mean = values.reduce(0, +) / Double(n)

        self.count = n
        self.mean = mean
        self.median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        self.min = sorted[0]
        self.max = sorted[n - 1]
        if n > 1 {
            let squares = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            self.standardDeviation = (squares / Double(n - 1)).squareRoot()
        } else {
            self.standardDeviation = nil
        }
    }
}
