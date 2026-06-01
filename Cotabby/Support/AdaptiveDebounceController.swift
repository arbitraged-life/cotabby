import Foundation

// MARK: - InputEvent

/// Describes the type of user input event that triggered a prediction schedule.
enum InputEvent {
    /// A regular printable character was typed.
    case character
    /// A space character was typed (sentence/word boundary).
    case space
    /// A punctuation character was typed (sentence boundary).
    case punctuation
    /// A deletion (backspace / forward-delete) was performed.
    case deletion
    /// Text was pasted (possibly large chunk; debounce aggressively).
    case paste
    /// A navigation key (arrow, Home, End, Page Up/Down) was pressed without changing text.
    case navigation
}

// MARK: - DebounceProfile

/// Controls the timing strategy used by `AdaptiveDebounceController`.
enum DebounceProfile {
    /// Uniform 300 ms for all input types. Suitable for most prose fields.
    case standard
    /// Sentence boundaries (space/punctuation) trigger 150 ms; mid-word typing triggers 400 ms.
    /// Ideal for chat, email, and document fields where completions at word boundaries feel snappy.
    case aggressive
    /// Uniform 500 ms. Useful for slower typists or noisy fields where premature generation wastes cycles.
    case relaxed
    /// 600 ms across the board. Designed for terminal/code fields where the user is often mid-command
    /// and a longer pause before generation avoids distracting completions.
    case terminal

    /// The baseline debounce interval for this profile (used for uniform profiles).
    var baseInterval: TimeInterval {
        switch self {
        case .standard:   return 0.300
        case .aggressive: return 0.150
        case .relaxed:    return 0.500
        case .terminal:   return 0.600
        }
    }
}

// MARK: - FieldAcceptanceTracker

/// Tracks how many suggestions have been shown in a given field without a user acceptance.
/// After `suppressionThreshold` consecutive misses, the tracker signals that debounce should
/// be lengthened to reduce wasted generation cycles.
final class FieldAcceptanceTracker {

    // MARK: Configuration

    /// Number of un-accepted suggestions before debounce suppression kicks in.
    var suppressionThreshold: Int

    /// Extra time added to the base interval once suppression is active.
    var suppressionPenalty: TimeInterval

    // MARK: State

    private var suggestionsShownWithoutAcceptance: Int = 0
    private(set) var isSuppressed: Bool = false

    // MARK: Init

    init(suppressionThreshold: Int = 8, suppressionPenalty: TimeInterval = 0.300) {
        self.suppressionThreshold = suppressionThreshold
        self.suppressionPenalty = suppressionPenalty
    }

    // MARK: Interface

    /// Call when a suggestion is displayed to the user.
    func recordSuggestionShown() {
        suggestionsShownWithoutAcceptance += 1
        isSuppressed = suggestionsShownWithoutAcceptance >= suppressionThreshold
    }

    /// Call when the user accepts a suggestion in this field.
    func recordAcceptance() {
        suggestionsShownWithoutAcceptance = 0
        isSuppressed = false
    }

    /// Resets the tracker entirely (e.g. on field focus change).
    func reset() {
        suggestionsShownWithoutAcceptance = 0
        isSuppressed = false
    }

    /// The additional debounce penalty that should be applied when suppression is active.
    var activePenalty: TimeInterval {
        isSuppressed ? suppressionPenalty : 0
    }
}

// MARK: - AdaptiveDebounceController

/// Computes per-event debounce intervals based on a `DebounceProfile`, consecutive-deletion
/// state, and per-field acceptance history.
///
/// Usage:
/// ```swift
/// let controller = AdaptiveDebounceController(profile: .aggressive)
/// let delay = controller.debounceInterval(for: .space)  // → 0.150
/// controller.recordDeletion()
/// let delayMidCorrection = controller.debounceInterval(for: .deletion) // → extended
/// ```
final class AdaptiveDebounceController {

    // MARK: Configuration

    let profile: DebounceProfile

    /// Number of consecutive deletions after which an additional penalty is applied.
    var deletionRunThreshold: Int = 3

    /// Extra time added to the interval when the user is in a deletion run (correcting a typo).
    var deletionRunPenalty: TimeInterval = 0.200

    // MARK: State

    /// Running count of back-to-back deletion events since the last non-deletion event.
    private(set) var consecutiveDeletions: Int = 0

    /// Per-field acceptance tracker. Callers should swap this out (or call `resetFieldTracker()`)
    /// when the focused field changes.
    let fieldTracker: FieldAcceptanceTracker

    // MARK: Init

    init(
        profile: DebounceProfile,
        fieldTracker: FieldAcceptanceTracker = FieldAcceptanceTracker()
    ) {
        self.profile = profile
        self.fieldTracker = fieldTracker
    }

    // MARK: Event Recording

    /// Informs the controller that a deletion event occurred. Used to detect correction runs.
    func recordDeletion() {
        consecutiveDeletions += 1
    }

    /// Informs the controller that a non-deletion event occurred, resetting the deletion counter.
    func recordNonDeletionEvent() {
        consecutiveDeletions = 0
    }

    /// Resets per-field state when the user moves focus to a new input field.
    func resetFieldState() {
        consecutiveDeletions = 0
        fieldTracker.reset()
    }

    // MARK: Core Interval Calculation

    /// Returns the debounce interval appropriate for the given `InputEvent`, factoring in the
    /// active profile, current deletion-run state, and field-level acceptance suppression.
    func debounceInterval(for event: InputEvent) -> TimeInterval {
        // Track deletion streaks.
        switch event {
        case .deletion:
            recordDeletion()
        default:
            recordNonDeletionEvent()
        }

        let base = baseInterval(for: event)
        let deletionPenalty = isInDeletionRun ? deletionRunPenalty : 0
        let acceptancePenalty = fieldTracker.activePenalty

        return base + deletionPenalty + acceptancePenalty
    }

    // MARK: Private Helpers

    /// Whether the user is currently in a consecutive deletion run long enough to trigger a penalty.
    private var isInDeletionRun: Bool {
        consecutiveDeletions >= deletionRunThreshold
    }

    /// The base interval for the given event, before any dynamic penalties are applied.
    private func baseInterval(for event: InputEvent) -> TimeInterval {
        switch profile {
        case .standard:
            return 0.300

        case .aggressive:
            return aggressiveInterval(for: event)

        case .relaxed:
            return 0.500

        case .terminal:
            return 0.600
        }
    }

    /// Interval logic for `.aggressive`: fast at sentence boundaries, slower mid-word.
    private func aggressiveInterval(for event: InputEvent) -> TimeInterval {
        switch event {
        case .space, .punctuation:
            // Sentence / word boundary — high confidence the user paused intentionally.
            return 0.150
        case .character:
            // Mid-word — wait a bit longer so we don't thrash while the word is still forming.
            return 0.400
        case .deletion:
            // Use the mid-word interval for deletions; the deletion-run penalty will stack on top.
            return 0.400
        case .paste:
            // Paste can be large; give it a bit of breathing room.
            return 0.300
        case .navigation:
            // Navigation doesn't change text; use a moderate delay.
            return 0.300
        }
    }
}
