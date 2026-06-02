import Foundation

/// Stores typed text inputs locally for personalization.
///
/// All data is stored in a local file within the app's container — never transmitted.
/// Records are stored as newline-delimited JSON for easy append and read.
///
/// The coordinator appends text whenever the user types (if `isInputStorageEnabled`), and
/// `PersonalizationEngine` reads historical data to bias word-choice probabilities.
final class InputHistoryStore: @unchecked Sendable {
    static let shared = InputHistoryStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.cotabby.inputHistoryStore", qos: .utility)

    struct Entry: Codable {
        let text: String
        let timestamp: Date
        let appBundleID: String?
        let hadAcceptedCompletion: Bool
    }

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Cotabby", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("input_history.jsonl")
    }

    /// Append a typing session to the history.
    func record(text: String, appBundleID: String?, hadAcceptedCompletion: Bool) {
        let entry = Entry(
            text: text,
            timestamp: Date(),
            appBundleID: appBundleID,
            hadAcceptedCompletion: hadAcceptedCompletion
        )
        queue.async { [weak self] in
            guard let self else { return }
            guard let data = try? JSONEncoder().encode(entry) else { return }
            let line = data + Data("\n".utf8)
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(line)
                    handle.closeFile()
                }
            } else {
                try? line.write(to: self.fileURL)
            }
        }
    }

    /// Load all entries (for personalization engine). Returns most recent N entries.
    func recentEntries(limit: Int = 1000) -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        let decoder = JSONDecoder()
        var entries: [Entry] = []
        for line in lines.suffix(limit) {
            if let entry = try? decoder.decode(Entry.self, from: Data(line)) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// Total number of stored entries.
    var entryCount: Int {
        guard let data = try? Data(contentsOf: fileURL) else { return 0 }
        return data.split(separator: UInt8(ascii: "\n")).count
    }

    /// Wipe all stored data.
    func clearAll() {
        queue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }
}
