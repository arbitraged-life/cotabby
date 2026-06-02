import Foundation

// MARK: - Insertion & Overlay enums

/// Which text-insertion mechanism the host app requires for reliable delivery.
enum InsertionStrategy: String, Codable, CaseIterable, Sendable {
    case syntheticKeystroke
    case pasteboardPaste
    case pasteAndMatchStyle
    case axAttributeWrite
}

/// How the completion overlay should render for this app.
enum OverlayPreference: String, Codable, CaseIterable, Sendable {
    /// Inline ghost text at the caret.
    case inline
    /// Floating mirror card below the caret.
    case mirror
    /// No overlay at all (secure/suppressed fields).
    case hidden
}

// MARK: - AppPolicy

/// The full resolved policy that governs Cotabby's behaviour in a particular app + field context.
struct AppPolicy: Sendable, Equatable {
    var completionsEnabled: Bool = true
    var midLineAllowed: Bool = true
    var insertionStrategy: InsertionStrategy = .syntheticKeystroke
    var overlayPreference: OverlayPreference = .inline
    var fontSizeAdjustmentFactor: Double = 1.0
    var verticalAlignmentOffset: Double = 0.0
    var debounceProfile: DebounceProfile = .standard
    var fieldTypeOverride: FieldType? = nil
    var customPromptHint: String? = nil

    static let `default` = AppPolicy()
}

// MARK: - AppOverride

/// A partial policy override keyed by bundle ID and/or domain.
struct AppOverride: Sendable {
    var bundleIdentifier: String?
    var domain: String?
    var completionsEnabled: Bool?
    var midLineAllowed: Bool?
    var insertionStrategy: InsertionStrategy?
    var overlayPreference: OverlayPreference?
    var fontSizeAdjustmentFactor: Double?
    var verticalAlignmentOffset: Double?
    var debounceProfile: DebounceProfile?
    var fieldTypeOverride: FieldType?
    var customPromptHint: String?

    /// Returns true if this override matches the given target.
    func matches(bundleID: String?, targetDomain: String?) -> Bool {
        if let bid = bundleIdentifier, bid == bundleID { return true }
        if let d = domain, let td = targetDomain {
            let normalized = td.lowercased().replacingOccurrences(of: "www.", with: "")
            if normalized.hasSuffix(d) || normalized == d { return true }
        }
        return false
    }

    /// Applies this override onto a base policy (non-nil fields win).
    func apply(to policy: inout AppPolicy) {
        if let v = completionsEnabled { policy.completionsEnabled = v }
        if let v = midLineAllowed { policy.midLineAllowed = v }
        if let v = insertionStrategy { policy.insertionStrategy = v }
        if let v = overlayPreference { policy.overlayPreference = v }
        if let v = fontSizeAdjustmentFactor { policy.fontSizeAdjustmentFactor *= v }
        if let v = verticalAlignmentOffset { policy.verticalAlignmentOffset += v }
        if let v = debounceProfile { policy.debounceProfile = v }
        if let v = fieldTypeOverride { policy.fieldTypeOverride = v }
        if let v = customPromptHint { policy.customPromptHint = v }
    }
}

// MARK: - AppCompatibilityStore

/// Central registry of per-app behavioural overrides. Ships a built-in table and supports
/// user additions at runtime.
final class AppCompatibilityStore: Sendable {
    static let shared = AppCompatibilityStore()

    /// User-configurable overrides (applied after built-ins, always win).
    var userOverrides: [AppOverride] = []

    private let builtInOverrides: [AppOverride]

    private init() {
        // Terminals
        let terminalBIDs = [
            "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
            "com.mitchellh.ghostty", "org.alacritty", "net.kovidgoyal.kitty",
            "com.github.wez.wezterm"
        ]
        let terminalOverrides = terminalBIDs.map { bid in
            AppOverride(bundleIdentifier: bid, midLineAllowed: false,
                        insertionStrategy: .syntheticKeystroke, overlayPreference: .mirror,
                        debounceProfile: .terminal, fieldTypeOverride: .terminal)
        }

        // Password managers — suppress everything
        let passwordBIDs = ["com.1password.1password", "com.agilebits.onepassword7",
                           "com.bitwarden.desktop", "com.dashlane.Dashlane"]
        let passwordOverrides = passwordBIDs.map { bid in
            AppOverride(bundleIdentifier: bid, completionsEnabled: false, overlayPreference: .hidden)
        }

        // Code editors — just disable environment context (handled in prompt, not policy)
        let codeOverrides = [
            AppOverride(bundleIdentifier: "com.apple.dt.Xcode", debounceProfile: .aggressive, fieldTypeOverride: .code),
            AppOverride(bundleIdentifier: "com.microsoft.VSCode", debounceProfile: .aggressive, fieldTypeOverride: .code),
            AppOverride(bundleIdentifier: "com.todesktop.230313mzl4w4u92", debounceProfile: .aggressive, fieldTypeOverride: .code),
        ]

        // Web apps requiring paste-and-match-style
        let pasteMatchOverrides = [
            AppOverride(domain: "docs.google.com", insertionStrategy: .pasteAndMatchStyle,
                        overlayPreference: .mirror, fontSizeAdjustmentFactor: 0.96),
            AppOverride(domain: "mail.google.com", insertionStrategy: .pasteAndMatchStyle,
                        verticalAlignmentOffset: 1.0),
            AppOverride(bundleIdentifier: "com.tinyspeck.slackmacgap",
                        insertionStrategy: .pasteAndMatchStyle, overlayPreference: .mirror),
            AppOverride(domain: "slack.com", insertionStrategy: .pasteAndMatchStyle, overlayPreference: .mirror),
            AppOverride(bundleIdentifier: "com.hnc.Discord",
                        insertionStrategy: .pasteAndMatchStyle, overlayPreference: .mirror),
            AppOverride(domain: "discord.com", insertionStrategy: .pasteAndMatchStyle, overlayPreference: .mirror),
            AppOverride(domain: "notion.so", insertionStrategy: .pasteAndMatchStyle, overlayPreference: .mirror),
        ]

        // Browser-specific
        let browserOverrides = [
            AppOverride(bundleIdentifier: "com.apple.Safari", fontSizeAdjustmentFactor: 0.98, verticalAlignmentOffset: 1.0),
        ]

        // WeChat — chunked injection (handled by caller mapping to chunkedInjection strategy)
        let wechatOverrides = [
            AppOverride(bundleIdentifier: "com.tencent.xinWeChat", fieldTypeOverride: .chat)
        ]

        builtInOverrides = terminalOverrides + passwordOverrides + codeOverrides
            + pasteMatchOverrides + browserOverrides + wechatOverrides
    }

    /// Resolves the full policy for a given app context.
    func policy(for bundleID: String?, domain: String? = nil, fieldRole: String? = nil) -> AppPolicy {
        var result = AppPolicy.default

        // Apply built-in overrides
        for override in builtInOverrides where override.matches(bundleID: bundleID, targetDomain: domain) {
            override.apply(to: &result)
        }

        // Apply user overrides (take precedence)
        for override in userOverrides where override.matches(bundleID: bundleID, targetDomain: domain) {
            override.apply(to: &result)
        }

        // AX role-based suppression
        if fieldRole == "AXSecureTextField" {
            result.completionsEnabled = false
            result.overlayPreference = .hidden
        }

        return result
    }
}
