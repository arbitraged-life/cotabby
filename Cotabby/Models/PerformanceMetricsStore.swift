import Combine
import Foundation
import Logging

/// File overview:
/// In-memory + UserDefaults-backed ring buffer of the most recent LLM generation latencies.
/// Capped at `maximumEntries` so the persisted blob stays small and the Performance settings pane
/// renders a bounded list without virtualization. Records flow in from `SuggestionEngineRouter`
/// only when the user has enabled performance tracking in Settings, so the default user pays no
/// storage or write cost.

/// One recorded LLM request — kept intentionally narrow: just the three fields the
/// Performance pane shows. Codable so the whole array round-trips through UserDefaults
/// as a JSON blob.
struct PerformanceMetricEntry: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let timestamp: Date
    let modelName: String
    let latencyMs: Int
    /// Approximate number of characters sent as context (prefix + suffix + instructions).
    /// Nil for entries recorded before context tracking was added.
    let contextCharacters: Int?
    /// Approximate model context window capacity in characters. When `contextCharacters` exceeds
    /// this value the prompt was likely truncated by the backend.
    let contextCapacityCharacters: Int?

    /// True when recorded context usage exceeded the model's estimated capacity.
    var isContextTruncated: Bool {
        guard let used = contextCharacters, let capacity = contextCapacityCharacters else {
            return false
        }
        return used > capacity
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        modelName: String,
        latencyMs: Int,
        contextCharacters: Int? = nil,
        contextCapacityCharacters: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.modelName = modelName
        self.latencyMs = latencyMs
        self.contextCharacters = contextCharacters
        self.contextCapacityCharacters = contextCapacityCharacters
    }
}

@MainActor
final class PerformanceMetricsStore: ObservableObject {
    /// Hard cap on retained entries. The UI assumes the entire list is renderable without
    /// virtualization, so growing this past a few hundred would require revisiting the pane.
    static let maximumEntries = 100

    @Published private(set) var entries: [PerformanceMetricEntry]

    private let userDefaults: UserDefaults
    private static let entriesDefaultsKey = "cotabbyPerformanceMetricEntries"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        entries = Self.loadEntries(from: userDefaults)
    }

    /// Append a new metric and drop the oldest entries above the cap. Persists after every record
    /// because the cap keeps the JSON blob small (well under 10 KB) and the write happens at most
    /// once per LLM request — far below any debouncing threshold.
    func record(
        modelName: String,
        latencyMs: Int,
        timestamp: Date = Date(),
        contextCharacters: Int? = nil,
        contextCapacityCharacters: Int? = nil
    ) {
        let entry = PerformanceMetricEntry(
            timestamp: timestamp,
            modelName: modelName,
            latencyMs: latencyMs,
            contextCharacters: contextCharacters,
            contextCapacityCharacters: contextCapacityCharacters
        )
        var updated = entries
        updated.append(entry)
        if updated.count > Self.maximumEntries {
            updated.removeFirst(updated.count - Self.maximumEntries)
        }
        entries = updated
        persist(updated)
    }

    func clear() {
        guard !entries.isEmpty else { return }
        entries = []
        userDefaults.removeObject(forKey: Self.entriesDefaultsKey)
    }

    private func persist(_ entries: [PerformanceMetricEntry]) {
        // Encoding `[PerformanceMetricEntry]` (UUID/Date/String/Int) shouldn't fail in practice, but
        // a silent return here would make "metrics vanish between sessions" undiagnosable. Log the
        // underlying error so the cause shows up in the standard JSONL stream when it does happen.
        do {
            let data = try JSONEncoder().encode(entries)
            userDefaults.set(data, forKey: Self.entriesDefaultsKey)
        } catch {
            CotabbyLogger.app.error(
                "Failed to persist performance metrics: \(error.localizedDescription)",
                metadata: ["entry_count": .stringConvertible(entries.count)]
            )
        }
    }

    private static func loadEntries(from userDefaults: UserDefaults) -> [PerformanceMetricEntry] {
        guard let data = userDefaults.data(forKey: Self.entriesDefaultsKey),
              let decoded = try? JSONDecoder().decode([PerformanceMetricEntry].self, from: data)
        else {
            return []
        }
        if decoded.count > maximumEntries {
            return Array(decoded.suffix(maximumEntries))
        }
        return decoded
    }
}
