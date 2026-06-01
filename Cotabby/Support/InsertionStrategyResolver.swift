import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - InsertionStrategy

/// Describes how a completion string should be delivered into the focused input field.
///
/// Each case maps to a distinct OS-level mechanism so callers can pick the one most likely to
/// succeed for a given host app (rich-text editors, browser inputs, terminal emulators, etc.).
enum InsertionStrategy: Equatable {
    /// Synthesize individual key-down/key-up CGEvents for each Unicode character. Lowest common
    /// denominator; works everywhere synthetic input is accepted but is the slowest path for long
    /// completions and can misfire on non-US keyboard layouts.
    case syntheticKeystroke

    /// Write the text to the general pasteboard, synthesize Cmd+V to paste, then restore the
    /// previous pasteboard contents after a short delay. Fast for any length of text; may produce
    /// a formatted paste in rich-text hosts.
    case pasteboardPaste

    /// Same as `.pasteboardPaste` but synthesizes Cmd+Opt+Shift+V ("Paste and Match Style"),
    /// which strips rich formatting and matches the destination's font in AppKit text views.
    case pasteAndMatchStyle

    /// Attempt to write the text directly to the focused accessibility element's
    /// `AXSelectedText` attribute, bypassing the keyboard entirely. Requires the Accessibility
    /// permission. Silent on hosts that expose a writable `AXSelectedText`.
    case axAttributeWrite

    /// Break the text into fixed-size chunks and insert each one via `.syntheticKeystroke` with a
    /// small inter-chunk delay. Useful for hosts (e.g. some web terminals) that drop events when
    /// they arrive in rapid bursts.
    case chunkedInjection(chunkSize: Int)
}

// MARK: - CompletionInserting

/// A type that can insert a completion string into the currently focused input using a caller-
/// supplied strategy.
protocol CompletionInserting: AnyObject {
    /// Insert `text` using the specified `strategy`.
    ///
    /// Throws `InsertionError` on failure. Implementations that synthesize events must return on
    /// the main actor so that CGEvent posting and NSPasteboard access are serialised correctly.
    @MainActor
    func insert(_ text: String, using strategy: InsertionStrategy) async throws
}

// MARK: - InsertionError

enum InsertionError: Error, CustomStringConvertible {
    case cgEventSourceUnavailable
    case pasteboardWriteFailed
    case axWriteFailed(AXError)
    case unsupportedCharacter(Character)
    case noFocusedElement

    var description: String {
        switch self {
        case .cgEventSourceUnavailable:
            return "Could not create a CGEventSource for synthetic keystroke injection."
        case .pasteboardWriteFailed:
            return "NSPasteboard write failed during pasteboard-paste insertion."
        case let .axWriteFailed(error):
            return "AXUIElementSetAttributeValue returned error \(error.rawValue)."
        case let .unsupportedCharacter(char):
            return "Character '\(char)' could not be mapped to a CGKeyCode."
        case .noFocusedElement:
            return "Could not obtain the focused AXUIElement for attribute-write insertion."
        }
    }
}

// MARK: - SynthesizedEventMarker

/// Stamps CGEvents synthesized by Cotabby so that Cotabby's own event monitors can recognise and
/// ignore them, preventing re-entrant processing.
///
/// Usage: call `stamp(_:)` before posting any CGEvent, and `isCotabbyEvent(_:)` inside tap
/// callbacks to filter out self-generated events.
enum SynthesizedEventMarker {
    /// An arbitrary non-zero value that fits in a 64-bit signed integer and is unlikely to collide
    /// with values set by the system or other apps.
    static let markerValue: Int64 = 0x436F_7461_6262_7901 // "Cotabby\x01"

    /// Stamps `event` with the Cotabby marker so downstream taps can skip it.
    static func stamp(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: markerValue)
    }

    /// Returns `true` when `event` was synthesized by this process via `stamp(_:)`.
    static func isCotabbyEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == markerValue
    }
}

// MARK: - PasteboardSnapshot

/// Captures all current items on the general pasteboard and can restore them later.
///
/// Ownership of the snapshot is explicit: call `restore()` once the paste is complete. The
/// snapshot is one-shot; calling `restore()` more than once is safe but a no-op after the first
/// call.
final class PasteboardSnapshot {
    private let pasteboard: NSPasteboard
    private var items: [NSPasteboardItem]?
    private var restored = false

    /// Captures the current pasteboard state.
    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        items = Self.deepCopy(of: pasteboard.pasteboardItems ?? [])
    }

    /// Restores the pasteboard to the state captured at initialisation. Safe to call from any
    /// thread, but NSPasteboard should be accessed on the main thread in practice.
    func restore() {
        guard !restored, let savedItems = items else { return }
        restored = true
        pasteboard.clearContents()
        if !savedItems.isEmpty {
            pasteboard.writeObjects(savedItems)
        }
    }

    // MARK: Private helpers

    /// Deep-copies pasteboard items so that a later `clearContents()` call cannot mutate the
    /// captured state through the original references.
    private static func deepCopy(of items: [NSPasteboardItem]) -> [NSPasteboardItem] {
        items.compactMap { original -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in original.types {
                guard let data = original.data(forType: type) else { continue }
                copy.setData(data, forType: type)
            }
            return copy
        }
    }
}

// MARK: - MultiStrategyInserter

/// Concrete implementation of `CompletionInserting` that dispatches to the appropriate OS API
/// based on the requested `InsertionStrategy`.
///
/// All methods are isolated to `@MainActor` because CGEvent posting, NSPasteboard access, and
/// Accessibility API calls each require the main run loop.
@MainActor
final class MultiStrategyInserter: CompletionInserting {
    // MARK: Configuration

    /// Delay in nanoseconds before the previous pasteboard contents are restored after a
    /// Cmd+V / Cmd+Opt+Shift+V synthesise. 120 ms gives AppKit text views enough time to read
    /// the pasteboard during paste processing.
    static let pasteboardRestoreDelayNanoseconds: UInt64 = 120_000_000

    /// Inter-chunk delay for `.chunkedInjection`, in nanoseconds. 16 ms (~1 display frame) gives
    /// most hosts time to flush the previous chunk before the next one arrives.
    static let chunkedInjectionInterChunkDelayNanoseconds: UInt64 = 16_000_000

    // MARK: CompletionInserting

    func insert(_ text: String, using strategy: InsertionStrategy) async throws {
        switch strategy {
        case .syntheticKeystroke:
            try insertViaSyntheticKeystrokes(text)

        case .pasteboardPaste:
            try await insertViaPasteboard(text, matchStyle: false)

        case .pasteAndMatchStyle:
            try await insertViaPasteboard(text, matchStyle: true)

        case .axAttributeWrite:
            try insertViaAXAttribute(text)

        case let .chunkedInjection(chunkSize):
            try await insertViaChunkedInjection(text, chunkSize: max(1, chunkSize))
        }
    }

    // MARK: - Strategy Implementations

    // MARK: Synthetic Keystrokes

    /// Synthesizes a key-down + key-up pair for each Unicode scalar in `text`.
    ///
    /// Characters that cannot be mapped to a virtual key code are posted as Unicode keystroke
    /// events using `CGEvent(keyboardEventSource:virtualKey:keyDown:)` with `keyCode = 0` and the
    /// Unicode code point written via `keyboardSetUnicodeString`.
    private func insertViaSyntheticKeystrokes(_ text: String) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InsertionError.cgEventSourceUnavailable
        }

        for scalar in text.unicodeScalars {
            try postUnicodeKeystroke(scalar: scalar, source: source)
        }
    }

    /// Posts a single Unicode scalar as a key-down + key-up CGEvent pair.
    private func postUnicodeKeystroke(scalar: Unicode.Scalar, source: CGEventSource) throws {
        // Use keyCode 0 for all characters; overwrite the Unicode string so the host sees the
        // correct character regardless of the keyboard layout installed.
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            throw InsertionError.cgEventSourceUnavailable
        }

        var codeUnit = scalar.value
        keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit)
        keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit)

        SynthesizedEventMarker.stamp(keyDown)
        SynthesizedEventMarker.stamp(keyUp)

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: Pasteboard Paste

    /// Writes `text` to the general pasteboard, synthesizes a paste shortcut, then schedules
    /// pasteboard restoration after `pasteboardRestoreDelayNanoseconds`.
    private func insertViaPasteboard(_ text: String, matchStyle: Bool) async throws {
        let snapshot = PasteboardSnapshot()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore()
            throw InsertionError.pasteboardWriteFailed
        }

        try synthesizePasteShortcut(matchStyle: matchStyle)

        // Restore asynchronously after the host has had time to read the pasteboard.
        Task { [snapshot] in
            try? await Task.sleep(nanoseconds: Self.pasteboardRestoreDelayNanoseconds)
            await MainActor.run { snapshot.restore() }
        }
    }

    /// Synthesizes Cmd+V or Cmd+Opt+Shift+V depending on `matchStyle`.
    private func synthesizePasteShortcut(matchStyle: Bool) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InsertionError.cgEventSourceUnavailable
        }

        // Virtual key code 9 = V on all standard Mac keyboard layouts.
        let vKeyCode: CGKeyCode = 9

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            throw InsertionError.cgEventSourceUnavailable
        }

        var flags: CGEventFlags = .maskCommand
        if matchStyle {
            // Cmd+Opt+Shift+V = "Paste and Match Style"
            flags.formUnion([.maskAlternate, .maskShift])
        }
        keyDown.flags = flags
        keyUp.flags   = flags

        SynthesizedEventMarker.stamp(keyDown)
        SynthesizedEventMarker.stamp(keyUp)

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    // MARK: Accessibility Attribute Write

    /// Attempts to inject `text` by writing to `AXSelectedText` on the focused AXUIElement.
    ///
    /// This bypasses the keyboard and event tap pipeline entirely. It requires the Accessibility
    /// permission and only succeeds on hosts that expose a writable `AXSelectedText` attribute
    /// (most native AppKit / UIKit-derived text views do; many Electron / web views do not).
    private func insertViaAXAttribute(_ text: String) throws {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElementRef: CFTypeRef?
        let fetchError = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementRef
        )

        guard fetchError == .success, let ref = focusedElementRef else {
            throw InsertionError.noFocusedElement
        }

        // swiftlint:disable:next force_cast
        let focusedElement = ref as! AXUIElement

        let writeError = AXUIElementSetAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        guard writeError == .success else {
            throw InsertionError.axWriteFailed(writeError)
        }
    }

    // MARK: Chunked Injection

    /// Splits `text` into chunks of at most `chunkSize` characters and injects each via
    /// `.syntheticKeystroke` with a short inter-chunk delay.
    private func insertViaChunkedInjection(_ text: String, chunkSize: Int) async throws {
        let chunks = text.chunked(by: chunkSize)
        for (index, chunk) in chunks.enumerated() {
            try insertViaSyntheticKeystrokes(chunk)
            // No delay after the last chunk.
            if index < chunks.count - 1 {
                try? await Task.sleep(nanoseconds: Self.chunkedInjectionInterChunkDelayNanoseconds)
            }
        }
    }
}

// MARK: - String + chunked(by:)

private extension String {
    /// Splits the receiver into an array of substrings each containing at most `size` characters.
    func chunked(by size: Int) -> [String] {
        guard size > 0, !isEmpty else { return [self] }
        var result: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[index ..< end]))
            index = end
        }
        return result
    }
}
