import Foundation

// Classifies the currently focused accessibility element into a semantic field type.
// All classification logic is pure (no AX reads, no side effects).

// MARK: - FieldType

/// Semantic category of the focused input element.
enum FieldType: String, Codable, CaseIterable, Sendable {
    case prose, code, terminal, searchBox, password, chat, url, unknown
}

// MARK: - FieldClassification

struct FieldClassification: Equatable, Sendable {
    let type: FieldType
    let confidence: Confidence
    let isSecure: Bool
    let isMultiLine: Bool

    enum Confidence: String, Equatable, Sendable {
        case high, medium, low
    }
}

// MARK: - FieldTypeClassifier

final class FieldTypeClassifier: Sendable {

    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "org.alacritty", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm"
    ]

    private static let codeBundleIDs: Set<String> = [
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
        "com.microsoft.VSCodeInsiders"
    ]

    private static let chatBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.MobileSMS",
        "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.tencent.xinWeChat"
    ]

    private static let passwordKeywords = ["password", "passcode", "passwd", "pin", "2fa", "mfa", "totp", "cvv", "secret"]
    private static let searchKeywords = ["search", "find", "filter", "query"]
    private static let urlKeywords = ["url", "address", "http", "link"]

    func classify(
        role: String?,
        subrole: String?,
        bundleID: String?,
        title: String?,
        placeholder: String?,
        traits: Set<String> = []
    ) -> FieldClassification {
        let placeholderLower = placeholder?.lowercased() ?? ""
        let isTextArea = role == "AXTextArea"

        // Password — highest priority (security)
        if role == "AXSecureTextField" || traits.contains("secure") {
            return FieldClassification(type: .password, confidence: .high, isSecure: true, isMultiLine: false)
        }
        if Self.passwordKeywords.contains(where: { placeholderLower.contains($0) }) {
            return FieldClassification(type: .password, confidence: .medium, isSecure: true, isMultiLine: false)
        }

        // Terminal
        if let bid = bundleID, Self.terminalBundleIDs.contains(bid) {
            return FieldClassification(type: .terminal, confidence: .high, isSecure: false, isMultiLine: true)
        }

        // Code editor
        if let bid = bundleID, Self.codeBundleIDs.contains(bid) {
            return FieldClassification(type: .code, confidence: .high, isSecure: false, isMultiLine: isTextArea)
        }

        // URL bar
        if subrole == "AXURLTextField" {
            return FieldClassification(type: .url, confidence: .high, isSecure: false, isMultiLine: false)
        }
        if !isTextArea && Self.urlKeywords.contains(where: { placeholderLower.contains($0) }) {
            return FieldClassification(type: .url, confidence: .medium, isSecure: false, isMultiLine: false)
        }

        // Search box
        if subrole == "AXSearchField" {
            return FieldClassification(type: .searchBox, confidence: .high, isSecure: false, isMultiLine: false)
        }
        if role == "AXTextField" && Self.searchKeywords.contains(where: { placeholderLower.contains($0) }) {
            return FieldClassification(type: .searchBox, confidence: .medium, isSecure: false, isMultiLine: false)
        }

        // Chat
        if let bid = bundleID, Self.chatBundleIDs.contains(bid) {
            return FieldClassification(type: .chat, confidence: .high, isSecure: false, isMultiLine: isTextArea)
        }

        // Prose (multi-line in non-code apps)
        if isTextArea {
            return FieldClassification(type: .prose, confidence: .low, isSecure: false, isMultiLine: true)
        }

        return FieldClassification(type: .unknown, confidence: .low, isSecure: false, isMultiLine: false)
    }
}
