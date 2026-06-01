import Combine
import Foundation

/// Tracks local-only usage statistics for the Settings analytics view.
///
/// All data lives in UserDefaults — never transmitted off-device. Counts reset
/// only when the user explicitly taps "Reset Statistics."
@MainActor
final class UsageAnalytics: ObservableObject {
    static let shared = UsageAnalytics()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let suggestionsShown = "cotabbyAnalyticsSuggestionsShown"
        static let suggestionsAccepted = "cotabbyAnalyticsSuggestionsAccepted"
        static let suggestionsRejected = "cotabbyAnalyticsSuggestionsRejected"
        static let wordsAccepted = "cotabbyAnalyticsWordsAccepted"
        static let charactersAccepted = "cotabbyAnalyticsCharactersAccepted"
        static let sessionStartDate = "cotabbyAnalyticsSessionStart"
    }

    @Published private(set) var suggestionsShown: Int
    @Published private(set) var suggestionsAccepted: Int
    @Published private(set) var suggestionsRejected: Int
    @Published private(set) var wordsAccepted: Int
    @Published private(set) var charactersAccepted: Int
    @Published private(set) var trackingSince: Date

    private init() {
        suggestionsShown = defaults.integer(forKey: Key.suggestionsShown)
        suggestionsAccepted = defaults.integer(forKey: Key.suggestionsAccepted)
        suggestionsRejected = defaults.integer(forKey: Key.suggestionsRejected)
        wordsAccepted = defaults.integer(forKey: Key.wordsAccepted)
        charactersAccepted = defaults.integer(forKey: Key.charactersAccepted)
        if let date = defaults.object(forKey: Key.sessionStartDate) as? Date {
            trackingSince = date
        } else {
            trackingSince = Date()
            defaults.set(trackingSince, forKey: Key.sessionStartDate)
        }
    }

    // MARK: – Recording

    func recordSuggestionShown() {
        suggestionsShown += 1
        defaults.set(suggestionsShown, forKey: Key.suggestionsShown)
    }

    func recordAcceptance(text: String) {
        suggestionsAccepted += 1
        let wordCount = text.split(whereSeparator: { $0.isWhitespace }).count
        wordsAccepted += wordCount
        charactersAccepted += text.count
        defaults.set(suggestionsAccepted, forKey: Key.suggestionsAccepted)
        defaults.set(wordsAccepted, forKey: Key.wordsAccepted)
        defaults.set(charactersAccepted, forKey: Key.charactersAccepted)
    }

    func recordRejection() {
        suggestionsRejected += 1
        defaults.set(suggestionsRejected, forKey: Key.suggestionsRejected)
    }

    // MARK: – Computed

    var acceptanceRate: Double {
        let total = suggestionsAccepted + suggestionsRejected
        guard total > 0 else { return 0 }
        return Double(suggestionsAccepted) / Double(total)
    }

    var daysTracking: Int {
        max(1, Calendar.current.dateComponents([.day], from: trackingSince, to: Date()).day ?? 1)
    }

    var wordsPerDay: Double {
        Double(wordsAccepted) / Double(daysTracking)
    }

    // MARK: – Reset

    func resetAll() {
        suggestionsShown = 0
        suggestionsAccepted = 0
        suggestionsRejected = 0
        wordsAccepted = 0
        charactersAccepted = 0
        trackingSince = Date()
        defaults.set(0, forKey: Key.suggestionsShown)
        defaults.set(0, forKey: Key.suggestionsAccepted)
        defaults.set(0, forKey: Key.suggestionsRejected)
        defaults.set(0, forKey: Key.wordsAccepted)
        defaults.set(0, forKey: Key.charactersAccepted)
        defaults.set(trackingSince, forKey: Key.sessionStartDate)
    }
}
