import Foundation

// File overview:
// Single composition point that turns a focused-input snapshot into a fully resolved per-field
// behaviour policy. This is the seam that wires four previously-inert decision modules
// (`AppCompatibilityStore`, `FieldTypeClassifier`, `AdaptiveDebounceController`, and
// `InsertionStrategyResolver`) into the live suggestion pipeline.
//
// Architectural role:
// `SuggestionCoordinator` resolves one of these per focus change and consults the result at the
// three pure decision points it already owns — the generation gate, the debounce timing, and the
// prompt build. Keeping the composition here means the coordinator stays orchestration code and
// the policy rules stay unit-testable in isolation.

// MARK: - ResolvedFieldPolicy

/// The fully-resolved behaviour for the currently focused field, composed from the per-app override
/// table and the semantic field-type classifier. A value type so change detection is cheap and the
/// coordinator can cache it across keystrokes without re-resolving on every prediction.
struct ResolvedFieldPolicy: Equatable, Sendable {
    /// The per-app behavioural policy (insertion strategy, overlay preference, gating, timing).
    let policy: AppPolicy
    /// The effective semantic field type: the app override wins, otherwise the classifier's guess.
    let fieldType: FieldType
    /// The debounce timing strategy this field should use.
    let debounceProfile: DebounceProfile
    /// Soft prompt hints derived from the field type and any app-specific custom hint. Appended to
    /// the user's custom rules at request-build time, exactly like personalization vocabulary — so
    /// they steer the model without forcing structure.
    let promptHints: [String]
    /// Whether completions are allowed at all in this app/field (false for password managers,
    /// secure fields, etc.). The coordinator's existing availability gate still runs; this is an
    /// additional, app-policy-driven veto.
    let completionsAllowed: Bool
    /// Whether mid-line completions are permitted in this app (false for terminals).
    let midLineAllowed: Bool
    /// The insertion mechanism this app's policy prefers. The live accept path honours
    /// `.syntheticKeystroke` directly; richer strategies are decision-wired and logged but routed
    /// through the proven synthetic path until the multi-strategy inserter shares the live
    /// suppression contract (see `SuggestionCoordinator` acceptance path).
    let insertionStrategy: InsertionStrategy

    /// The neutral default used when there is no focused field to resolve against.
    static let `default` = ResolvedFieldPolicy(
        policy: .default,
        fieldType: .unknown,
        debounceProfile: .standard,
        promptHints: [],
        completionsAllowed: true,
        midLineAllowed: true,
        insertionStrategy: .syntheticKeystroke
    )
}

// MARK: - FieldPolicyResolver

/// Composes `AppCompatibilityStore` + `FieldTypeClassifier` into a single `ResolvedFieldPolicy`.
/// Pure with respect to the inputs it is handed — it performs no AX reads of its own, so it stays
/// trivially testable.
final class FieldPolicyResolver {
    private let store: AppCompatibilityStore
    private let classifier: FieldTypeClassifier

    init(
        store: AppCompatibilityStore = .shared,
        classifier: FieldTypeClassifier = FieldTypeClassifier()
    ) {
        self.store = store
        self.classifier = classifier
    }

    /// Resolves the behaviour policy for a focused-input snapshot. Returns `.default` when there is
    /// no focused field so callers can treat "no field" and "neutral field" uniformly.
    ///
    /// `domain` is an optional best-effort web host (for browser/web-app overrides keyed by domain);
    /// pass `nil` when unknown — the bundle-ID overrides still apply.
    func resolve(snapshot: FocusedInputSnapshot?, domain: String? = nil) -> ResolvedFieldPolicy {
        guard let snapshot else { return .default }

        let policy = store.policy(
            for: snapshot.bundleIdentifier,
            domain: domain,
            fieldRole: snapshot.role
        )

        let classification = classifier.classify(
            role: snapshot.role,
            subrole: snapshot.subrole,
            bundleID: snapshot.bundleIdentifier,
            title: nil,
            placeholder: nil,
            traits: snapshot.isSecure ? ["secure"] : []
        )

        // App override wins over the classifier's structural guess: a code-editor bundle ID is a
        // stronger signal than an AX role that some Electron editors mislabel.
        let effectiveFieldType = policy.fieldTypeOverride ?? classification.type

        return ResolvedFieldPolicy(
            policy: policy,
            fieldType: effectiveFieldType,
            debounceProfile: policy.debounceProfile,
            promptHints: Self.promptHints(for: effectiveFieldType, customHint: policy.customPromptHint),
            completionsAllowed: policy.completionsEnabled,
            midLineAllowed: policy.midLineAllowed,
            insertionStrategy: policy.insertionStrategy
        )
    }

    /// Builds the soft prompt hints for a field type. Kept deliberately gentle — these are
    /// preferences, not commands, so the model still matches the surrounding text first.
    static func promptHints(for fieldType: FieldType, customHint: String?) -> [String] {
        var hints: [String] = []

        switch fieldType {
        case .code:
            hints.append("This text field is a code editor. Prefer code-appropriate continuations "
                + "(identifiers, syntax) and avoid prose unless the cursor is in a comment or string.")
        case .terminal:
            hints.append("This is a terminal/shell field. Prefer short shell-command continuations; "
                + "do not write prose.")
        case .chat:
            hints.append("This is a chat message field. Keep continuations short, casual, and "
                + "conversational.")
        case .url:
            hints.append("This is a URL/address field. Continue a plausible URL or path, not prose.")
        case .searchBox:
            hints.append("This is a search field. Keep continuations to a short query, not a "
                + "sentence.")
        case .prose, .unknown, .password:
            break
        }

        if let customHint, !customHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hints.append(customHint)
        }

        return hints
    }
}
