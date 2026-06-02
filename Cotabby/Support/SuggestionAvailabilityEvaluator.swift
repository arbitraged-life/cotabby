import Foundation

/// File overview:
/// Centralizes the repeated gating rules that decide whether Cotabby can react to the current focus
/// and whether a refreshed prediction is worthwhile. This is intentionally pure and deterministic.
///
/// The value of this helper is consistency: permission/focus checks appear in several coordinator
/// paths, and moving them here prevents small wording or branching differences from creeping in.
enum SuggestionAvailabilityEvaluator {
    static func disabledReason(
        globallyEnabled: Bool = true,
        disabledAppBundleIdentifiers: Set<String> = [],
        inputMonitoringGranted: Bool,
        screenRecordingGranted: Bool,
        focusSnapshot: FocusSnapshot,
        pausedUntil: Date? = nil,
        checkCapability: Bool = true
    ) -> String? {
        guard globallyEnabled else {
            return "Cotabby is turned off."
        }

        // Menu-bar Pause / snooze (#8). A deadline in the future closes the gate; a past or nil value
        // is a no-op so an elapsed snooze naturally re-opens without any extra bookkeeping here.
        if let pausedUntil, pausedUntil > Date() {
            return "Cotabby is paused until \(PauseStatusFormatter.shortTime(pausedUntil))."
        }

        if let bundleIdentifier = focusSnapshot.bundleIdentifier,
           disabledAppBundleIdentifiers.contains(bundleIdentifier) {
            return "Cotabby is disabled in \(focusSnapshot.applicationName)."
        }

        if TerminalAppDetector.isTerminal(bundleIdentifier: focusSnapshot.bundleIdentifier) {
            return "Cotabby is not available in terminal apps."
        }

        guard inputMonitoringGranted else {
            return "Input Monitoring permission is required before Cotabby can react to typing."
        }

        guard screenRecordingGranted else {
            return "Screen Recording permission is required before Cotabby can build visual context "
                + "for autocomplete."
        }

        guard checkCapability else {
            return nil
        }

        switch focusSnapshot.capability {
        case .supported:
            return nil
        case let .blocked(reason), let .unsupported(reason):
            return reason
        }
    }

    static func shouldSchedulePrediction(
        globallyEnabled: Bool = true,
        disabledAppBundleIdentifiers: Set<String> = [],
        inputMonitoringGranted: Bool,
        screenRecordingGranted: Bool,
        focusSnapshot: FocusSnapshot,
        pausedUntil: Date? = nil
    ) -> Bool {
        disabledReason(
            globallyEnabled: globallyEnabled,
            disabledAppBundleIdentifiers: disabledAppBundleIdentifiers,
            inputMonitoringGranted: inputMonitoringGranted,
            screenRecordingGranted: screenRecordingGranted,
            focusSnapshot: focusSnapshot,
            pausedUntil: pausedUntil
        ) == nil
    }

    /// Whether the environment allows visual context capture to start.
    ///
    /// Delegates to `disabledReason` with capability checking disabled so transient field
    /// states (text selected, secure field) are intentionally ignored — OCR should start
    /// early in those cases and be ready by the time the user begins typing.
    ///
    /// Fast mode is checked here, and deliberately NOT in `disabledReason`: it suppresses only the
    /// screenshot/OCR pipeline. Predictions still run (they just go out without visual context), so
    /// `disabledReason` / `shouldSchedulePrediction` must stay unaffected.
    static func shouldCaptureVisualContext(
        globallyEnabled: Bool = true,
        disabledAppBundleIdentifiers: Set<String> = [],
        inputMonitoringGranted: Bool,
        screenRecordingGranted: Bool,
        focusSnapshot: FocusSnapshot,
        isFastModeEnabled: Bool = false
    ) -> Bool {
        guard !isFastModeEnabled else {
            return false
        }

        return disabledReason(
            globallyEnabled: globallyEnabled,
            disabledAppBundleIdentifiers: disabledAppBundleIdentifiers,
            inputMonitoringGranted: inputMonitoringGranted,
            screenRecordingGranted: screenRecordingGranted,
            focusSnapshot: focusSnapshot,
            checkCapability: false
        ) == nil
    }

    static func shouldSchedulePredictionWhenVisualContextBecomesReady(
        focusSnapshot: FocusSnapshot,
        matching identity: FocusedInputIdentity
    ) -> Bool {
        guard case .supported = focusSnapshot.capability,
              let context = focusSnapshot.context,
              context.identity == identity
        else {
            return false
        }

        return SuggestionRequestFactory.shouldGenerateSuggestion(for: context.precedingText)
    }
}

/// Small, shared formatter for rendering a snooze deadline (#8) in user-facing strings — both the
/// gate's disabled reason and the menu-bar status line. Kept pure so it is trivially testable and so
/// the two surfaces never drift in wording.
enum PauseStatusFormatter {
    /// A short, locale-aware clock time (e.g. "3:45 PM" or "15:45"), used inside "paused until …".
    static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// The full menu-bar status line, e.g. "Paused until 3:45 PM". Returns `nil` when not paused so
    /// callers can fall back to their normal status rendering.
    static func menuBarStatus(pausedUntil: Date?) -> String? {
        guard let pausedUntil, pausedUntil > Date() else { return nil }
        return "Paused until \(shortTime(pausedUntil))"
    }
}
