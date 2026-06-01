import Foundation

// MARK: - FieldType

/// The semantic category of the focused input field.
///
/// Cotabby uses this to tune completion behaviour — terminals skip autocorrect, password fields
/// disable completions entirely, code editors prefer `axAttributeWrite` insertion, and so on.
/// The value is inferred from AX role/subrole + bundle identifier; per-app overrides may pin it.
enum FieldType: String, Codable, CaseIterable, Sendable {
    /// Long-form natural-language writing: email, documents, notes.
    case prose
    /// Source-code or REPL fields where syntax-awareness matters.
    case code
    /// Terminal emulators — stdin streams, not standard text fields.
    case terminal
    /// Short, transient query boxes (Spotlight, browser omnibar, Find bar).
    case searchBox
    /// Credential or secret fields; completions are always suppressed.
    case password
    /// Conversational messaging UIs: Slack, iMessage, Discord, WeChat.
    case chat
}

// MARK: - InsertionStrategy

/// How Cotabby physically delivers accepted text into the host field.
///
/// The right choice depends on the host's AX/input stack:
/// - Most native AppKit fields accept `syntheticKeystroke`.
/// - Rich-text web editors (Google Docs, Notion) need `pasteAndMatchStyle` to avoid injecting
///   styled RTF that clobbers the surrounding font.
/// - Some accessibility-hostile editors (terminals, canvases) respond best to `axAttributeWrite`.
/// - `pasteboardPaste` is a last resort for fields that ignore both keyboard events and AX writes.
enum InsertionStrategy: String, Codable, CaseIterable, Sendable {
    /// Replay the accepted text as a stream of CGEvents, character by character.
    /// Works for essentially all native AppKit text fields.
    case syntheticKeystroke
    /// Write to the pasteboard then send ⌘V. Slower but more broadly compatible than synthetic keys.
    case pasteboardPaste
    /// Write to the pasteboard then send ⌘⇧V (Paste and Match Style). Strips inline formatting,
    /// preventing the host's rich-text engine from inheriting Cotabby's pasteboard attributes.
    case pasteAndMatchStyle
    /// Write directly to the AX `AXValue` attribute of the focused element.
    /// Avoids the keyboard event pipeline entirely; useful for canvas-backed text layers.
    case axAttributeWrite
}

// MARK: - OverlayPreference

/// Controls where (or whether) the completion overlay is rendered for a specific app or field.
///
/// This is the per-app counterpart to `MirrorPreference`, which captures the *global* user
/// setting. When an `AppOverride` specifies an `OverlayPreference`, it wins over the global
/// setting for that bundle identifier.
enum OverlayPreference: String, Codable, CaseIterable, Sendable {
    /// Ghost text drawn inline, immediately after the caret.
    case inline
    /// Floating card anchored below the focused field (mirror / popup).
    case mirror
    /// Suppress all overlay rendering for this app or field type.
    case hidden
}

// MARK: - DebounceProfile

/// How aggressively Cotabby waits before firing a completion request after a keypress.
///
/// Terminals and code editors benefit from a slower trigger so that fast typers do not generate
/// wasteful requests on every character. Conversational chat UIs (where sentences end abruptly
/// and the user pauses naturally) can use a shorter window.
enum DebounceProfile: String, Codable, CaseIterable, Sendable {
    /// 300 ms — the default for most text fields.
    case standard
    /// 500 ms — for high-throughput inputs (terminals, code editors) where requests are expensive.
    case aggressive
    /// 150 ms — for conversational fields where latency matters more than request economy.
    case relaxed
}

// MARK: - AppPolicy

/// The full resolved policy that governs Cotabby's behaviour in a particular app + field context.
///
/// `AppPolicy` is a *resolved* value: it is never stored partially. The `AppCompatibilityStore`
/// produces one by merging built-in overrides with user overrides on top of a default baseline.
/// Callers read it as a plain struct and never mutate it.
struct AppPolicy: Equatable, Sendable {
    // MARK: Core toggles

    /// Whether completions are generated and shown at all for this app/field.
    /// Set to `false` for password fields, captured-input games, and similar contexts.
    var completionsEnabled: Bool

    /// Whether Cotabby may offer a completion when the caret is in the middle of a line
    /// (i.e., there is non-whitespace text to the right of the insertion point).
    /// Terminals and single-line search boxes often set this to `false`.
    var midLineAllowed: Bool

    // MARK: Insertion

    /// How accepted text is delivered to the host field.
    var insertionStrategy: InsertionStrategy

    // MARK: Overlay

    /// Where (or whether) the completion overlay is rendered.
    var overlayPreference: OverlayPreference

    // MARK: Visual adjustments

    /// Multiplier applied to the system-measured font size when sizing overlay text.
    /// 1.0 = no adjustment. Values < 1.0 shrink the overlay glyph; > 1.0 enlarges it.
    /// Useful for apps that report an AX font size that differs from the visual size.
    var fontSizeAdjustmentFactor: Double

    /// Vertical offset (in screen points) added to the computed caret Y origin before placing
    /// the inline overlay. Positive moves the overlay down; negative moves it up.
    /// Compensates for apps whose AX caret rect is vertically misaligned with the rendered text.
    var verticalAlignmentOffset: Double

    // MARK: Timing

    /// How long Cotabby waits after the last keypress before triggering a completion request.
    var debounceProfile: DebounceProfile

    // MARK: Semantic overrides

    /// Pins the field type classification for this app, overriding automatic AX-role inference.
    /// `nil` means "infer from AX role as usual".
    var fieldTypeOverride: FieldType?

    /// An optional free-form string injected into the system prompt for this app.
    /// Allows app-specific persona or style hints (e.g. "You are completing shell commands" for
    /// terminals, or "Match the user's casual chat style" for messaging apps).
    var customPromptHint: String?

    // MARK: Default baseline

    /// The out-of-the-box policy used for any app that has no override.
    static let `default` = AppPolicy(
        completionsEnabled: true,
        midLineAllowed: true,
        insertionStrategy: .syntheticKeystroke,
        overlayPreference: .inline,
        fontSizeAdjustmentFactor: 1.0,
        verticalAlignmentOffset: 0,
        debounceProfile: .standard,
        fieldTypeOverride: nil,
        customPromptHint: nil
    )
}

// MARK: - AppOverride

/// A *partial* policy override for a specific app or domain.
///
/// Every property is optional: `nil` means "inherit from the baseline / lower-priority override".
/// This mirrors how CSS cascades — only the properties explicitly set in the override participate
/// in the merge; the rest fall through to the default.
///
/// Matching priority (highest to lowest):
///   1. `bundleIdentifier` exact match
///   2. `domain` suffix match (e.g. `"google.com"` matches `"docs.google.com"`)
///   3. Global `AppPolicy.default`
struct AppOverride: Sendable {
    /// The target app's CFBundleIdentifier (e.g. `"com.apple.Safari"`). `nil` = match any bundle.
    var bundleIdentifier: String?

    /// A reverse-DNS domain suffix used for web-based apps where the host field lives in a browser
    /// but the page origin determines the best policy (e.g. `"docs.google.com"`).
    var domain: String?

    // MARK: Partial policy fields (all optional — nil means "don't override")

    var completionsEnabled: Bool?
    var midLineAllowed: Bool?
    var insertionStrategy: InsertionStrategy?
    var overlayPreference: OverlayPreference?
    var fontSizeAdjustmentFactor: Double?
    var verticalAlignmentOffset: Double?
    var debounceProfile: DebounceProfile?
    var fieldTypeOverride: FieldType?
    var customPromptHint: String?

    // MARK: Init

    init(
        bundleIdentifier: String? = nil,
        domain: String? = nil,
        completionsEnabled: Bool? = nil,
        midLineAllowed: Bool? = nil,
        insertionStrategy: InsertionStrategy? = nil,
        overlayPreference: OverlayPreference? = nil,
        fontSizeAdjustmentFactor: Double? = nil,
        verticalAlignmentOffset: Double? = nil,
        debounceProfile: DebounceProfile? = nil,
        fieldTypeOverride: FieldType? = nil,
        customPromptHint: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.domain = domain
        self.completionsEnabled = completionsEnabled
        self.midLineAllowed = midLineAllowed
        self.insertionStrategy = insertionStrategy
        self.overlayPreference = overlayPreference
        self.fontSizeAdjustmentFactor = fontSizeAdjustmentFactor
        self.verticalAlignmentOffset = verticalAlignmentOffset
        self.debounceProfile = debounceProfile
        self.fieldTypeOverride = fieldTypeOverride
        self.customPromptHint = customPromptHint
    }

    /// Returns a new `AppPolicy` that applies the non-nil fields of this override on top of `base`.
    func applying(to base: AppPolicy) -> AppPolicy {
        AppPolicy(
            completionsEnabled: completionsEnabled ?? base.completionsEnabled,
            midLineAllowed: midLineAllowed ?? base.midLineAllowed,
            insertionStrategy: insertionStrategy ?? base.insertionStrategy,
            overlayPreference: overlayPreference ?? base.overlayPreference,
            fontSizeAdjustmentFactor: fontSizeAdjustmentFactor ?? base.fontSizeAdjustmentFactor,
            verticalAlignmentOffset: verticalAlignmentOffset ?? base.verticalAlignmentOffset,
            debounceProfile: debounceProfile ?? base.debounceProfile,
            fieldTypeOverride: fieldTypeOverride ?? base.fieldTypeOverride,
            customPromptHint: customPromptHint ?? base.customPromptHint
        )
    }
}

// MARK: - AppCompatibilityStore

/// Central registry of per-app and per-domain compatibility overrides.
///
/// `AppCompatibilityStore` ships a curated set of built-in overrides derived from real-world
/// compatibility testing across the macOS app ecosystem. User overrides (Phase 2) will be
/// layered on top in a separate pass.
///
/// Resolution order for a given (bundleID, domain, fieldRole) triple:
///   1. User-supplied overrides matching `bundleIdentifier` — highest priority.
///   2. User-supplied overrides matching `domain` suffix.
///   3. Built-in overrides matching `bundleIdentifier`.
///   4. Built-in overrides matching `domain` suffix.
///   5. AX-role-based policy adjustments (applied inside `policy(for:domain:fieldRole:)`).
///   6. `AppPolicy.default` — lowest priority.
///
/// Thread safety: the store is read-only after initialisation and is safe to call from any thread.
final class AppCompatibilityStore: @unchecked Sendable {

    // MARK: Shared instance

    static let shared = AppCompatibilityStore()

    // MARK: Stored overrides

    /// User-supplied overrides. Empty in Phase 1; populated from Settings in Phase 2.
    private(set) var userOverrides: [AppOverride] = []

    /// Built-in overrides shipped with Cotabby.
    let builtInOverrides: [AppOverride]

    // MARK: Init

    private init() {
        builtInOverrides = Self.makeBuiltInOverrides()
    }

    // MARK: - Policy resolution

    /// Resolves the effective `AppPolicy` for a given focused-field context.
    ///
    /// - Parameters:
    ///   - bundleID: The `CFBundleIdentifier` of the frontmost application, or `nil` if unknown.
    ///   - domain:   The effective domain of the focused web content (e.g. `"docs.google.com"`),
    ///               or `nil` if the field is not inside a web view.
    ///   - fieldRole: The AX role string of the focused element (e.g. `"AXTextField"`,
    ///               `"AXTextArea"`, `"AXSecureTextField"`), or `nil` if unavailable.
    /// - Returns: A fully resolved `AppPolicy` ready for use by the suggestion pipeline.
    func policy(for bundleID: String?, domain: String?, fieldRole: String?) -> AppPolicy {
        var resolved = AppPolicy.default

        // Layer 4 — built-in bundle-ID overrides (lowest explicit layer)
        for override in builtInOverrides {
            if let bid = override.bundleIdentifier, let id = bundleID, bid == id {
                resolved = override.applying(to: resolved)
                break
            }
        }

        // Layer 3 — built-in domain overrides
        if let domain {
            for override in builtInOverrides {
                if override.bundleIdentifier == nil,
                   let od = override.domain,
                   domain == od || domain.hasSuffix("." + od) {
                    resolved = override.applying(to: resolved)
                    break
                }
            }
        }

        // Layer 2 — user bundle-ID overrides
        for override in userOverrides {
            if let bid = override.bundleIdentifier, let id = bundleID, bid == id {
                resolved = override.applying(to: resolved)
                break
            }
        }

        // Layer 1 — user domain overrides (highest explicit layer)
        if let domain {
            for override in userOverrides {
                if override.bundleIdentifier == nil,
                   let od = override.domain,
                   domain == od || domain.hasSuffix("." + od) {
                    resolved = override.applying(to: resolved)
                    break
                }
            }
        }

        // AX role adjustments — applied after explicit overrides so they only fill in gaps.
        resolved = applyFieldRoleAdjustments(to: resolved, fieldRole: fieldRole)

        return resolved
    }

    // MARK: - AX-role adjustments

    /// Applies lightweight adjustments that can be inferred purely from the AX role string,
    /// without knowing the host application. These run at the lowest priority so that any
    /// explicit override wins.
    private func applyFieldRoleAdjustments(to policy: AppPolicy, fieldRole: String?) -> AppPolicy {
        guard let role = fieldRole else { return policy }
        var adjusted = policy

        switch role {
        case "AXSecureTextField":
            // Never complete into password fields regardless of what the app override says.
            adjusted.completionsEnabled = false
            adjusted.overlayPreference = .hidden
            adjusted.fieldTypeOverride = adjusted.fieldTypeOverride ?? .password

        case "AXSearchField":
            adjusted.midLineAllowed = adjusted.midLineAllowed && false
            adjusted.fieldTypeOverride = adjusted.fieldTypeOverride ?? .searchBox
            adjusted.debounceProfile = adjusted.debounceProfile == .standard ? .relaxed : adjusted.debounceProfile

        default:
            break
        }

        return adjusted
    }

    // MARK: - Built-in override table

    // swiftlint:disable function_body_length
    private static func makeBuiltInOverrides() -> [AppOverride] {
        var overrides: [AppOverride] = []

        // ── Terminals ──────────────────────────────────────────────────────────────────────────
        // Terminals receive keystrokes rather than rich-text events. Synthetic keystrokes are the
        // right delivery mechanism. Mid-line completions are disabled because the shell cursor is
        // at the far right of the prompt almost all the time; there is no stable "right of caret"
        // text to avoid. Debounce is aggressive to avoid firing on every shell character.

        let terminalPolicy = AppOverride(
            insertionStrategy: .syntheticKeystroke,
            midLineAllowed: false,
            overlayPreference: .mirror,
            debounceProfile: .aggressive,
            fieldTypeOverride: .terminal,
            customPromptHint: "Complete shell commands and terminal input. Be concise and POSIX-correct."
        )

        func terminal(bundleID: String) -> AppOverride {
            AppOverride(
                bundleIdentifier: bundleID,
                completionsEnabled: terminalPolicy.completionsEnabled,
                midLineAllowed: terminalPolicy.midLineAllowed,
                insertionStrategy: terminalPolicy.insertionStrategy,
                overlayPreference: terminalPolicy.overlayPreference,
                debounceProfile: terminalPolicy.debounceProfile,
                fieldTypeOverride: terminalPolicy.fieldTypeOverride,
                customPromptHint: terminalPolicy.customPromptHint
            )
        }

        overrides += [
            terminal(bundleID: "com.googlecode.iterm2"),          // iTerm2
            terminal(bundleID: "dev.warp.desktop"),               // Warp
            terminal(bundleID: "com.mitchellh.ghostty"),          // Ghostty
            terminal(bundleID: "io.alacritty"),                   // Alacritty
            terminal(bundleID: "net.kovidgoyal.kitty"),           // Kitty
            terminal(bundleID: "com.github.wez.wezterm"),         // WezTerm
            terminal(bundleID: "com.apple.Terminal"),             // Terminal.app
        ]

        // ── Password managers ──────────────────────────────────────────────────────────────────
        // The entire application is credential-focused. Disable completions at the bundle level;
        // the AX-role rule above additionally kills individual AXSecureTextField fields everywhere.

        overrides += [
            AppOverride(
                bundleIdentifier: "com.agilebits.onepassword7",   // 1Password 7
                completionsEnabled: false,
                overlayPreference: .hidden,
                fieldTypeOverride: .password
            ),
            AppOverride(
                bundleIdentifier: "com.agilebits.onepassword8",   // 1Password 8
                completionsEnabled: false,
                overlayPreference: .hidden,
                fieldTypeOverride: .password
            ),
            AppOverride(
                bundleIdentifier: "com.bitwarden.desktop",        // Bitwarden
                completionsEnabled: false,
                overlayPreference: .hidden,
                fieldTypeOverride: .password
            ),
        ]

        // ── Code editors ──────────────────────────────────────────────────────────────────────
        // These editors have their own completion engine. We keep Cotabby active but use
        // `axAttributeWrite` to avoid fighting the editor's own synthetic-keystroke path.
        // Debounce is aggressive; mid-line completions are disabled in default settings but the
        // editor override leaves it to the user (nil = inherit from default = true).

        let codeEditorHint = "Complete source code. Match the surrounding language, style, and indentation."

        overrides += [
            AppOverride(
                bundleIdentifier: "com.apple.dt.Xcode",
                insertionStrategy: .axAttributeWrite,
                debounceProfile: .aggressive,
                fieldTypeOverride: .code,
                customPromptHint: codeEditorHint
            ),
            AppOverride(
                bundleIdentifier: "com.microsoft.VSCode",
                insertionStrategy: .axAttributeWrite,
                debounceProfile: .aggressive,
                fieldTypeOverride: .code,
                customPromptHint: codeEditorHint
            ),
            AppOverride(
                bundleIdentifier: "com.todesktop.230313mzl4w4u92", // Cursor
                insertionStrategy: .axAttributeWrite,
                debounceProfile: .aggressive,
                fieldTypeOverride: .code,
                customPromptHint: codeEditorHint
            ),
        ]

        // ── Google Docs (web) ──────────────────────────────────────────────────────────────────
        // Google Docs renders text on a canvas element. The only reliable insertion path is
        // pasteboard, and "Paste and Match Style" avoids injecting bold/colour spans from the
        // clipboard into the document's own styled runs.

        overrides += [
            AppOverride(
                domain: "docs.google.com",
                insertionStrategy: .pasteAndMatchStyle,
                overlayPreference: .mirror,
                debounceProfile: .standard,
                fieldTypeOverride: .prose,
                customPromptHint: "Complete document prose. Maintain the author's register and formatting conventions."
            ),
        ]

        // ── Slack ──────────────────────────────────────────────────────────────────────────────
        // Slack's Electron text area accepts synthetic keystrokes for short snippets but
        // occasionally drops characters under load. Paste-and-match-style is more reliable and
        // avoids injecting Slack's own message formatting.

        overrides += [
            AppOverride(
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                insertionStrategy: .pasteAndMatchStyle,
                debounceProfile: .relaxed,
                fieldTypeOverride: .chat,
                customPromptHint: "Complete a conversational Slack message. Keep the tone casual and direct."
            ),
        ]

        // ── Discord ───────────────────────────────────────────────────────────────────────────

        overrides += [
            AppOverride(
                bundleIdentifier: "com.hnc.Discord",
                insertionStrategy: .pasteAndMatchStyle,
                debounceProfile: .relaxed,
                fieldTypeOverride: .chat,
                customPromptHint: "Complete a conversational Discord message. Match the user's tone."
            ),
        ]

        // ── Safari ────────────────────────────────────────────────────────────────────────────
        // Safari's WKWebView fields generally work with synthetic keystrokes. Mirror preference
        // defers to the global setting (no overlay override here); inline works for most fields
        // once Safari exposes AX caret geometry.

        overrides += [
            AppOverride(
                bundleIdentifier: "com.apple.Safari",
                insertionStrategy: .syntheticKeystroke,
                debounceProfile: .standard
            ),
        ]

        // ── Google Chrome ─────────────────────────────────────────────────────────────────────
        // Chrome's Blink text fields accept synthetic keystrokes for most content-editable areas,
        // but rich-text editors embedded in pages (Google Docs, Notion, etc.) are caught by their
        // domain-level override above. For the browser shell (omnibar, devtools) the default is fine.

        overrides += [
            AppOverride(
                bundleIdentifier: "com.google.Chrome",
                insertionStrategy: .syntheticKeystroke,
                debounceProfile: .standard
            ),
        ]

        // ── WeChat ────────────────────────────────────────────────────────────────────────────
        // WeChat's macOS client uses a custom text engine that resists synthetic keystrokes at
        // high typing speeds. Paste-and-match-style is the safest insertion path; the chat
        // field type hints the model toward conversational Mandarin/English completions.

        overrides += [
            AppOverride(
                bundleIdentifier: "com.tencent.xinWeChat",
                insertionStrategy: .pasteAndMatchStyle,
                debounceProfile: .relaxed,
                fieldTypeOverride: .chat,
                customPromptHint: "Complete a WeChat message. Support both Chinese and English naturally."
            ),
        ]

        return overrides
    }
    // swiftlint:enable function_body_length
}
