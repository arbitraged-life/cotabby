import Foundation

// MARK: - InputEvent

/// Categorizes the most recent user input for debounce differentiation.
enum InputEvent: Sendable {
    case character
    case space
    case punctuation
    case deletion
    case paste
    case navigation
}

// MARK: - DebounceProfile

/// Controls the timing strategy used by `AdaptiveDebounceController`.
enum DebounceProfile: String, Codable, CaseIterable, Sendable {
    /// Uniform 300 ms for all input types.
    case standard
    /// 150 ms after space/punctuation, 400 ms mid-word.
    case aggressive
    /// Uniform 500 ms for noisy or slow-typer fields.
    case relaxed
    /// 600 ms — designed for terminal/code fields.
    case terminal
}

// MARK: - FieldAcceptanceTracker

/// Tracks per-field suggestion acceptance rate. Suppresses generation when the user
/// consistently ignores suggestions in this field.
final class FieldAcceptanceTracker: Sendable {
    private let suppressionThreshold: Int
    private var suggestionsShown: Int = 0
    private var acceptances: Int = 0

    var isSuppressed: Bool { suggestionsShown >= suppressionThreshold && acceptances == 0 }

    /// Extra debounce penalty (ms) when the field is being suppressed.
    var activePenalty: TimeInterval { isSuppressed ? 0.3 : 0.0 }

    init(suppressionThreshold: Int = 8) {
        self.suppressionThreshold = suppressionThreshold
    }

    func recordSuggestionShown() { suggestionsShown += 1 }
    func recordAcceptance() { acceptances += 1 }
    func reset() { suggestionsShown = 0; acceptances = 0 }
}

// MARK: - AdaptiveDebounceController

/// Computes context-aware debounce intervals based on the profile, recent input type,
/// consecutive deletions, and per-field acceptance history.
final class AdaptiveDebounceController {
    private let profile: DebounceProfile
    private let fieldTracker: FieldAcceptanceTracker
    private var consecutiveDeletions: Int = 0

    init(profile: DebounceProfile = .standard, fieldTracker: FieldAcceptanceTracker = FieldAcceptanceTracker()) {
        self.profile = profile
        self.fieldTracker = fieldTracker
    }

    /// Returns the debounce interval (seconds) for the given input event.
    func debounceInterval(for event: InputEvent) -> TimeInterval {
        // Track deletion runs
        if event == .deletion {
            consecutiveDeletions += 1
        } else {
            consecutiveDeletions = 0
        }

        let base: TimeInterval
        switch profile {
        case .standard:
            base = 0.3
        case .aggressive:
            switch event {
            case .space, .punctuation:
                base = 0.15   // Word boundary — user likely pausing
            case .character:
                base = 0.4    // Mid-word — user still typing
            case .deletion:
                base = 0.5    // Correcting — don't suggest yet
            case .paste:
                base = 0.2    // Paste then pause — suggest quickly
            case .navigation:
                base = 0.35
            }
        case .relaxed:
            base = 0.5
        case .terminal:
            base = 0.6
        }

        // Deletion run penalty: kicks in after 3+ consecutive backspaces
        let deletionPenalty: TimeInterval = consecutiveDeletions >= 3 ? 0.2 : 0.0

        return base + deletionPenalty + fieldTracker.activePenalty
    }

    func resetFieldState() {
        consecutiveDeletions = 0
        fieldTracker.reset()
    }
}
