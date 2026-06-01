import Foundation

/// Uses the user's typing history to compute word-frequency biases.
///
/// At personalization strength 0.0, no bias is applied. At 1.0, the user's most frequently
/// typed words and phrases get maximum preference in completion ranking.
///
/// This is a lightweight frequency-based approach: it builds a unigram frequency map from
/// stored inputs and exposes a bias score for any candidate token/word.
enum PersonalizationEngine {
    /// A word and its relative frequency in the user's history (0.0–1.0 scale).
    struct WordBias: Sendable {
        let word: String
        let frequency: Double
    }

    /// Build a frequency map from stored history.
    /// Returns the top N words with their relative frequencies.
    static func buildVocabularyBias(from entries: [InputHistoryStore.Entry], topN: Int = 500) -> [String: Double] {
        var counts: [String: Int] = [:]
        var totalWords = 0

        for entry in entries {
            let words = entry.text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            for word in words {
                let lower = word.lowercased()
                guard lower.count >= 2 else { continue }
                counts[lower, default: 0] += 1
                totalWords += 1
            }
        }

        guard totalWords > 0 else { return [:] }

        // Normalize to relative frequency and keep top N
        let sorted = counts.sorted { $0.value > $1.value }.prefix(topN)
        let maxCount = Double(sorted.first?.value ?? 1)

        var result: [String: Double] = [:]
        for (word, count) in sorted {
            result[word] = Double(count) / maxCount
        }
        return result
    }

    /// Returns a bias score for a candidate word given the user's vocabulary map and
    /// personalization strength.
    ///
    /// - Returns: A multiplier in range [1.0, 2.0] where 1.0 means no bias.
    static func biasScore(
        for word: String,
        vocabulary: [String: Double],
        strength: Double
    ) -> Double {
        let lower = word.lowercased()
        guard let frequency = vocabulary[lower] else { return 1.0 }
        // At max strength (1.0), a word at max frequency gets 2.0x bias
        return 1.0 + (frequency * strength)
    }
}
