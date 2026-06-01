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

    // Common English stop words that dominate frequency counts but carry no
    // stylistic signal. Filtered before selecting top-N vocabulary.
    private static let stopWords: Set<String> = [
        "the", "be", "to", "of", "and", "a", "in", "that", "have", "i",
        "it", "for", "not", "on", "with", "he", "as", "you", "do", "at",
        "this", "but", "his", "by", "from", "they", "we", "say", "her", "she",
        "or", "an", "will", "my", "one", "all", "would", "there", "their", "what",
        "so", "up", "out", "if", "about", "who", "get", "which", "go", "me",
        "when", "make", "can", "like", "time", "no", "just", "him", "know", "take",
        "people", "into", "year", "your", "good", "some", "could", "them", "see",
        "other", "than", "then", "now", "look", "only", "come", "its", "over",
        "think", "also", "back", "after", "use", "two", "how", "our", "work",
        "first", "well", "way", "even", "new", "want", "because", "any", "these",
        "give", "day", "most", "us", "is", "are", "was", "were", "been", "being",
        "has", "had", "did", "does", "am", "may", "might", "shall", "should",
        "very", "much", "more", "here", "still", "own", "such", "where", "why",
        "each", "too", "those"
    ]

    /// Build a frequency map from stored history.
    /// Returns the top N words with their relative frequencies.
    /// Filters common stop words so the vocabulary captures stylistic/domain-specific terms.
    static func buildVocabularyBias(from entries: [InputHistoryStore.Entry], topN: Int = 500) -> [String: Double] {
        var counts: [String: Int] = [:]
        var totalWords = 0

        for entry in entries {
            let words = entry.text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            for word in words {
                let lower = word.lowercased()
                guard lower.count >= 3 else { continue }
                guard !stopWords.contains(lower) else { continue }
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
