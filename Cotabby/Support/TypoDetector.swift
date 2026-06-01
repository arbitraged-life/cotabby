import AppKit
import Foundation

/// Detects likely typos in the current word being typed using the system spell checker.
///
/// Used by the suggestion coordinator to suppress completions that would extend a misspelled word.
/// Also provides suggested corrections for inline display.
///
/// Implementation leans on `NSSpellChecker` which performs local dictionary lookups — no network.
enum TypoDetector {
    /// Result of checking a word for typos.
    struct TypoCheckResult: Sendable {
        /// Whether the word is likely a typo.
        let isTypo: Bool
        /// Suggested corrections if any (empty when `isTypo == false`).
        let corrections: [String]
    }

    /// Checks whether `word` is likely a typo.
    ///
    /// Only inspects the current word (whitespace-delimited). Short words (< 3 chars) or
    /// words that look like identifiers (camelCase, underscores, digits) are never flagged.
    ///
    /// - Parameters:
    ///   - word: The word to check. Should be the current word the user is typing.
    ///   - language: Optional language hint. Defaults to the system language.
    /// - Returns: A `TypoCheckResult` indicating whether a typo was detected and any corrections.
    @MainActor
    static func check(word: String, language: String? = nil) -> TypoCheckResult {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)

        // Don't check very short words — too noisy.
        guard trimmed.count >= 3 else {
            return TypoCheckResult(isTypo: false, corrections: [])
        }

        // Skip words that look like code identifiers.
        if looksLikeIdentifier(trimmed) {
            return TypoCheckResult(isTypo: false, corrections: [])
        }

        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        let misspelledRange = checker.checkSpelling(
            of: trimmed,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )

        guard misspelledRange.location != NSNotFound else {
            return TypoCheckResult(isTypo: false, corrections: [])
        }

        let guesses = checker.guesses(
            forWordRange: range,
            in: trimmed,
            language: language,
            inSpellDocumentWithTag: 0
        ) ?? []

        return TypoCheckResult(isTypo: true, corrections: Array(guesses.prefix(3)))
    }

    /// Extracts the current word from the end of a text buffer.
    ///
    /// The "current word" is defined as the sequence of non-whitespace, non-punctuation characters
    /// at the tail of `text`. Returns nil if the text ends with whitespace (word boundary).
    static func currentWord(from text: String) -> String? {
        guard let lastChar = text.last, !lastChar.isWhitespace else {
            return nil
        }

        var word = ""
        for char in text.reversed() {
            if char.isWhitespace || char.isPunctuation {
                break
            }
            word = String(char) + word
        }
        return word.isEmpty ? nil : word
    }

    // MARK: - Private

    /// Returns true if the word looks like a code identifier (contains underscores, digits in the
    /// middle, or uses camelCase).
    private static func looksLikeIdentifier(_ word: String) -> Bool {
        if word.contains("_") { return true }
        if word.contains(where: { $0.isNumber }) { return true }
        // camelCase: lowercase start with at least one uppercase in the middle
        let hasInternalUppercase = word.dropFirst().contains(where: { $0.isUppercase })
        if word.first?.isLowercase == true && hasInternalUppercase { return true }
        return false
    }
}
