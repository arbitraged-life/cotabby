import AppKit
import Carbon.HIToolbox

// MARK: - ResolvedInsertionStrategy

/// The concrete insertion mechanism to use for delivering a completion into the host app.
enum ResolvedInsertionStrategy: Equatable {
    /// Synthesize per-character CGEvents. Universal but slow for long text.
    case syntheticKeystroke
    /// Pasteboard + Cmd+V. Fast, may produce formatted paste in rich-text hosts.
    case pasteboardPaste
    /// Pasteboard + Cmd+Opt+Shift+V. Strips formatting (Google Docs, Slack, Discord).
    case pasteAndMatchStyle
    /// AXUIElementSetAttributeValue on kAXSelectedTextAttribute. Instant, no event artifacts.
    case axAttributeWrite
    /// Send text in chunks with inter-chunk delay (WeChat compatibility).
    case chunkedInjection(chunkSize: Int)
}

// MARK: - InsertionError

enum InsertionError: Error {
    case cgEventSourceUnavailable
    case pasteboardWriteFailed
    case axWriteFailed(AXError)
    case noFocusedElement
}

// MARK: - SynthesizedEventMarker

/// Tags CGEvents so Cotabby's own AX observer ignores self-generated input.
enum SynthesizedEventMarker {
    static let userData: Int64 = 0x436F_7461_6262_7901 // "Cotabby\x01"

    static func stamp(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: userData)
    }

    static func isCotabbyEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == userData
    }
}

// MARK: - CompletionInserting

protocol CompletionInserting {
    @MainActor func insert(_ text: String, using strategy: ResolvedInsertionStrategy) async throws
}

// MARK: - PasteboardSnapshot

/// Saves and restores the general pasteboard contents around a paste-based insertion.
final class PasteboardSnapshot {
    private var items: [[NSPasteboard.PasteboardType: Data]] = []
    private var restored = false

    init() {
        let pb = NSPasteboard.general
        for item in pb.pasteboardItems ?? [] {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            items.append(dict)
        }
    }

    func restore() {
        guard !restored else { return }
        restored = true
        let pb = NSPasteboard.general
        pb.clearContents()
        let pasteItems = items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(pasteItems)
    }
}

// MARK: - MultiStrategyInserter

/// Executes text insertion using the resolved strategy.
final class MultiStrategyInserter: CompletionInserting {
    @MainActor
    func insert(_ text: String, using strategy: ResolvedInsertionStrategy) async throws {
        switch strategy {
        case .syntheticKeystroke:
            try synthesizeKeystrokes(for: text)
        case .pasteboardPaste:
            try await pasteboardInsert(text, matchStyle: false)
        case .pasteAndMatchStyle:
            try await pasteboardInsert(text, matchStyle: true)
        case .axAttributeWrite:
            try axWrite(text)
        case let .chunkedInjection(chunkSize):
            try await chunkedInsert(text, chunkSize: chunkSize)
        }
    }

    // MARK: - Synthetic Keystrokes

    private func synthesizeKeystrokes(for text: String) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InsertionError.cgEventSourceUnavailable
        }
        for scalar in text.unicodeScalars {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }

            var codeUnit = UniChar(scalar.value)
            keyDown.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit)
            keyUp.keyboardSetUnicodeString(stringLength: 1, unicodeString: &codeUnit)
            SynthesizedEventMarker.stamp(keyDown)
            SynthesizedEventMarker.stamp(keyUp)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Pasteboard Paste

    private func pasteboardInsert(_ text: String, matchStyle: Bool) async throws {
        let snapshot = PasteboardSnapshot()
        let pb = NSPasteboard.general
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            throw InsertionError.pasteboardWriteFailed
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw InsertionError.cgEventSourceUnavailable
        }

        // Cmd+V (keyCode 9) or Cmd+Opt+Shift+V
        let vKeyCode: CGKeyCode = 9
        var flags: CGEventFlags = .maskCommand
        if matchStyle { flags.insert([.maskAlternate, .maskShift]) }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        if let keyDown, let keyUp {
            keyDown.flags = flags
            keyUp.flags = flags
            SynthesizedEventMarker.stamp(keyDown)
            SynthesizedEventMarker.stamp(keyUp)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }

        // Restore pasteboard after 120ms
        try await Task.sleep(nanoseconds: 120_000_000)
        snapshot.restore()
    }

    // MARK: - AX Attribute Write

    private func axWrite(_ text: String) throws {
        guard let axElement = AXHelper.focusedElement() else {
            throw InsertionError.noFocusedElement
        }

        let writeResult = AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard writeResult == .success else {
            throw InsertionError.axWriteFailed(writeResult)
        }
    }

    // MARK: - Chunked Injection

    private func chunkedInsert(_ text: String, chunkSize: Int) async throws {
        let chunks = stride(from: 0, to: text.count, by: chunkSize).map { start -> String in
            let startIdx = text.index(text.startIndex, offsetBy: start)
            let endIdx = text.index(startIdx, offsetBy: min(chunkSize, text.count - start))
            return String(text[startIdx ..< endIdx])
        }
        for chunk in chunks {
            try synthesizeKeystrokes(for: chunk)
            try await Task.sleep(nanoseconds: 16_000_000) // 16ms inter-chunk
        }
    }
}
