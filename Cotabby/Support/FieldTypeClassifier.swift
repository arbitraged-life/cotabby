import Foundation

/// File overview:
/// Classifies the currently focused accessibility element into a semantic field type so that
/// the suggestion pipeline can apply type-specific prompt policies, length caps, and suppression
/// rules without scattering bundle-ID lists or role heuristics across multiple callsites.
///
/// All classification logic is pure (no AX reads, no side effects) so it can be exercised in
/// unit tests without a live accessibility tree.

// MARK: - FieldType

/// Semantic category of the focused input element.
enum FieldType: String, Equatable, Hashable, Sendable, CaseIterable {
    /// Long-form natural-language writing (email bodies, documents, notes).
    case prose
    /// Source code or markup in a dedicated editor.
    case code
    /// A shell / terminal emulator input line.
    case terminal
    /// A single-line search or find bar.
    case searchBox
    /// A password or passcode entry field (content is masked).
    case password
    /// A messaging composer (Slack, Discord, Messages, etc.).
    case chat
    /// A URL / address bar.
    case url
    /// Could not be determined from the available signals.
    case unknown
}

// MARK: - FieldClassification

/// The result of classifying a focused accessibility element.
struct FieldClassification: Equatable, Sendable {
    /// Semantic field category.
    let type: FieldType
    /// How confident the classifier is in the result.
    let confidence: Confidence
    /// Whether the field masks its contents (e.g. AXSecureTextField).
    let isSecure: Bool
    /// Whether the field spans multiple lines (e.g. AXTextArea).
    let isMultiLine: Bool

    enum Confidence: String, Equatable, Sendable {
        case high
        case medium
        case low
    }

    /// Convenience initializer with the most common defaults.
    init(
        type: FieldType,
        confidence: Confidence,
        isSecure: Bool = false,
        isMultiLine: Bool = false
    ) {
        self.type = type
        self.confidence = confidence
        self.isSecure = isSecure
        self.isMultiLine = isMultiLine
    }
}

// MARK: - FieldTypeClassifier

/// Classifies a focused accessibility element using AX role/subrole, bundle identifier, title,
/// and placeholder text. All inputs are optional so callers can pass only the signals they have
/// without needing to hard-code fallback values.
final class FieldTypeClassifier {

    // MARK: Bundle-ID sets

    /// Terminal emulators. Kept here so policy changes live in one place.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.tabbyml.tabby-terminal",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
    ]

    /// IDEs / code editors where any text area is treated as a code field.
    private static let codeBundleIDs: Set<String> = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.AppCode",
        "com.jetbrains.WebStorm",
        "com.jetbrains.PyCharm",
        "com.jetbrains.RubyMine",
        "com.jetbrains.CLion",
        "com.jetbrains.GoLand",
        "com.jetbrains.rider",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.panic.Nova",
        "io.zed.zed",
        "io.zed.zed-preview",
        "com.github.atom",
        "com.visualstudio.windows",
    ]

    /// Chat / messaging apps.
    private static let chatBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",   // Slack
        "com.hnc.Discord",              // Discord
        "com.apple.MobileSMS",          // Messages (macOS)
        "com.apple.iChat",
        "WhatsApp",
        "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram",        // Telegram
        "com.tencent.xinWeChat",        // WeChat
        "com.microsoft.teams2",         // Teams
        "com.microsoft.teams",
        "com.facebook.archon",          // Messenger
        "com.skype.skype",
        "com.beeper.Beeper",
        "im.riot.app",                  // Element / Matrix
        "com.mattermost.desktop",
    ]

    // MARK: Keyword sets

    private static let passwordKeywords: [String] = [
        "password", "passcode", "passphrase", "secret", "pin",
    ]

    private static let searchKeywords: [String] = [
        "search", "find", "filter", "look up", "query",
    ]

    private static let urlKeywords: [String] = [
        "address", "url", "http", "https", "www",
    ]

    // MARK: Classification

    /// Returns a `FieldClassification` for the given accessibility signals.
    ///
    /// - Parameters:
    ///   - role:        AX role string (e.g. `AXTextField`, `AXTextArea`, `AXSecureTextField`).
    ///   - subrole:     AX subrole string (e.g. `AXSearchField`, `AXURLTextField`).
    ///   - bundleID:    Bundle identifier of the frontmost application.
    ///   - title:       AX title or label for the element.
    ///   - placeholder: AX placeholder value string shown when the field is empty.
    ///   - traits:      Arbitrary additional trait strings (reserved for future extension).
    func classify(
        role: String?,
        subrole: String?,
        bundleID: String?,
        title: String?,
        placeholder: String?,
        traits: Set<String>
    ) -> FieldClassification {
        let roleLower        = role?.lowercased() ?? ""
        let subroleNorm      = subrole ?? ""
        let placeholderLower = placeholder?.lowercased() ?? ""
        let titleLower       = title?.lowercased() ?? ""
        let bundleNorm       = bundleID ?? ""

        let isSecure   = roleLower.contains("securetextfield")
        let isTextArea = roleLower == "axtextarea" || role == "AXTextArea"

        // 1. Password — checked first; security always wins.
        if isSecure {
            return FieldClassification(type: .password, confidence: .high, isSecure: true, isMultiLine: false)
        }
        let placeholderMatchesPassword = Self.passwordKeywords.contains {
            placeholderLower.contains($0) || titleLower.contains($0)
        }
        if placeholderMatchesPassword {
            return FieldClassification(type: .password, confidence: .medium, isSecure: false, isMultiLine: false)
        }

        // 2. Terminal
        if let bid = bundleID, Self.terminalBundleIDs.contains(bid) {
            return FieldClassification(type: .terminal, confidence: .high, isSecure: false, isMultiLine: false)
        }

        // 3. Code — known IDE bundle IDs, or an AXTextArea inside a code editor.
        if let bid = bundleID, Self.codeBundleIDs.contains(bid) {
            return FieldClassification(
                type: .code,
                confidence: .high,
                isSecure: false,
                isMultiLine: isTextArea
            )
        }

        // 4. URL — explicit subrole takes priority over keyword matching.
        if subroleNorm == "AXURLTextField" {
            return FieldClassification(type: .url, confidence: .high, isSecure: false, isMultiLine: false)
        }
        let placeholderMatchesURL = Self.urlKeywords.contains {
            placeholderLower.contains($0) || titleLower.contains($0)
        }
        if placeholderMatchesURL && !isTextArea {
            return FieldClassification(type: .url, confidence: .medium, isSecure: false, isMultiLine: false)
        }

        // 5. Search box — single-line fields hinting at search/find.
        if subroleNorm == "AXSearchField" {
            return FieldClassification(type: .searchBox, confidence: .high, isSecure: false, isMultiLine: false)
        }
        let isTextField = roleLower == "axtextfield" || role == "AXTextField"
        if isTextField {
            let placeholderMatchesSearch = Self.searchKeywords.contains {
                placeholderLower.contains($0) || titleLower.contains($0)
            }
            if placeholderMatchesSearch {
                return FieldClassification(type: .searchBox, confidence: .medium, isSecure: false, isMultiLine: false)
            }
        }

        // 6. Chat / messaging composer.
        if let bid = bundleID, Self.chatBundleIDs.contains(bid) {
            return FieldClassification(
                type: .chat,
                confidence: .high,
                isSecure: false,
                isMultiLine: isTextArea
            )
        }

        // 7. Prose — multi-line text area in a non-code, non-terminal app.
        if isTextArea {
            return FieldClassification(type: .prose, confidence: .medium, isSecure: false, isMultiLine: true)
        }

        // 8. Unknown fallback.
        return FieldClassification(type: .unknown, confidence: .low, isSecure: false, isMultiLine: false)
    }
}
