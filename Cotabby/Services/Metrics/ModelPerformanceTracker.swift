import Combine
import Foundation

/// Richer per-request performance record for model comparison.
/// Stored alongside the existing `PerformanceMetricsStore` entries — this adds
/// fields the comparison view needs without breaking the existing pane.
struct ModelPerformanceRecord: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let modelName: String
    /// Time to first token in milliseconds.
    let ttftMs: Int
    /// Total request latency in milliseconds.
    let totalLatencyMs: Int
    /// Tokens generated in this request.
    let tokenCount: Int
    /// Decode speed: tokens per second (excluding TTFT).
    let decodeTokensPerSecond: Double

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        modelName: String,
        ttftMs: Int,
        totalLatencyMs: Int,
        tokenCount: Int,
        decodeTokensPerSecond: Double
    ) {
        self.id = id
        self.timestamp = timestamp
        self.modelName = modelName
        self.ttftMs = ttftMs
        self.totalLatencyMs = totalLatencyMs
        self.tokenCount = tokenCount
        self.decodeTokensPerSecond = decodeTokensPerSecond
    }
}

/// Aggregated stats for a single model across many requests.
struct ModelPerformanceSummary: Identifiable, Sendable {
    var id: String { modelName }
    let modelName: String
    let requestCount: Int
    let medianTTFTMs: Int
    let p90TTFTMs: Int
    let medianDecodeTokensPerSecond: Double
    let p90LatencyMs: Int
}

/// Tracks per-model performance for the comparison view.
/// Local-only, opt-in (respects `isPerformanceTrackingEnabled`), wipeable.
@MainActor
final class ModelPerformanceTracker: ObservableObject {
    static let shared = ModelPerformanceTracker()
    static let maximumRecords = 500

    @Published private(set) var records: [ModelPerformanceRecord]
    @Published private(set) var summaries: [ModelPerformanceSummary] = []

    private let userDefaults: UserDefaults
    private static let storageKey = "cotabbyModelPerformanceRecords"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        records = Self.load(from: userDefaults)
        recomputeSummaries()
    }

    func record(
        modelName: String,
        ttftMs: Int,
        totalLatencyMs: Int,
        tokenCount: Int,
        decodeTokensPerSecond: Double
    ) {
        let entry = ModelPerformanceRecord(
            modelName: modelName,
            ttftMs: ttftMs,
            totalLatencyMs: totalLatencyMs,
            tokenCount: tokenCount,
            decodeTokensPerSecond: decodeTokensPerSecond
        )
        var updated = records
        updated.append(entry)
        if updated.count > Self.maximumRecords {
            updated.removeFirst(updated.count - Self.maximumRecords)
        }
        records = updated
        persist(updated)
        recomputeSummaries()
    }

    func clear() {
        records = []
        summaries = []
        userDefaults.removeObject(forKey: Self.storageKey)
    }

    // MARK: - Private

    private func recomputeSummaries() {
        let grouped = Dictionary(grouping: records, by: \.modelName)
        summaries = grouped.map { name, entries in
            let ttfts = entries.map(\.ttftMs).sorted()
            let latencies = entries.map(\.totalLatencyMs).sorted()
            let speeds = entries.map(\.decodeTokensPerSecond).sorted()

            return ModelPerformanceSummary(
                modelName: name,
                requestCount: entries.count,
                medianTTFTMs: percentile(ttfts, 50),
                p90TTFTMs: percentile(ttfts, 90),
                medianDecodeTokensPerSecond: percentileDouble(speeds, 50),
                p90LatencyMs: percentile(latencies, 90)
            )
        }.sorted { $0.medianDecodeTokensPerSecond > $1.medianDecodeTokensPerSecond }
    }

    private func percentile(_ sorted: [Int], _ percentile: Int) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count) * Double(percentile) / 100.0)))
        return sorted[idx]
    }

    private func percentileDouble(_ sorted: [Double], _ percentile: Int) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count) * Double(percentile) / 100.0)))
        return sorted[idx]
    }

    private func persist(_ records: [ModelPerformanceRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from ud: UserDefaults) -> [ModelPerformanceRecord] {
        guard let data = ud.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ModelPerformanceRecord].self, from: data)
        else { return [] }
        return decoded.count > maximumRecords ? Array(decoded.suffix(maximumRecords)) : decoded
    }
}
