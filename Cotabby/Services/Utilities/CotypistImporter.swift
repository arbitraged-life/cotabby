import Foundation
import SQLite3

/// Imports typing history from a Cotypist database export into Cotabby's personalization store.
///
/// Cotypist stores data in a SQLCipher-encrypted SQLite DB (`cotypist.db`). Since Cotabby does not
/// bundle SQLCipher, this importer supports two paths:
///   1. An **unencrypted SQLite** copy of the Cotypist DB (user decrypts externally).
///   2. A **JSON/JSONL** export containing `textUpToCursor` records.
///
/// The importer extracts text content from `user_inputs.textUpToCursor` and converts each row into
/// a Cotabby `InputHistoryStore.Entry`, seeding the personalization vocabulary with the user's
/// prior writing history.
enum CotypistImporter {
    struct ImportResult: Sendable {
        let importedCount: Int
        let skippedCount: Int
        let errorMessage: String?
    }

    /// Imports from a user-selected file. Dispatches to the appropriate parser based on extension.
    static func importFile(at url: URL) async -> ImportResult {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "db", "sqlite", "sqlite3":
            return await importSQLiteDatabase(at: url)
        case "json":
            return importJSON(at: url)
        case "jsonl":
            return importJSONL(at: url)
        default:
            return ImportResult(
                importedCount: 0,
                skippedCount: 0,
                errorMessage: "Unsupported file type: .\(ext). Use .db, .json, or .jsonl."
            )
        }
    }

    // MARK: - SQLite (unencrypted)

    private static func importSQLiteDatabase(at url: URL) async -> ImportResult {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            return ImportResult(
                importedCount: 0,
                skippedCount: 0,
                errorMessage: "Failed to open database: \(msg). If the DB is encrypted, decrypt it first with sqlcipher."
            )
        }
        defer { sqlite3_close(db) }

        let query = """
            SELECT textUpToCursor, appBundleIdentifier, createdAt
            FROM user_inputs
            WHERE textUpToCursor IS NOT NULL AND length(textUpToCursor) > 0
            ORDER BY createdAt ASC
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            return ImportResult(importedCount: 0, skippedCount: 0, errorMessage: "Query failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        var imported = 0
        var skipped = 0
        let store = InputHistoryStore.shared
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let textPtr = sqlite3_column_text(stmt, 0) else {
                skipped += 1
                continue
            }
            let text = String(cString: textPtr)

            // Skip very short entries (< 10 chars) — not useful for vocabulary
            guard text.count >= 10 else {
                skipped += 1
                continue
            }

            let appBundleID: String?
            if let bundlePtr = sqlite3_column_text(stmt, 1) {
                appBundleID = String(cString: bundlePtr)
            } else {
                appBundleID = nil
            }

            store.record(text: text, appBundleID: appBundleID, hadAcceptedCompletion: false)
            imported += 1
        }

        return ImportResult(importedCount: imported, skippedCount: skipped, errorMessage: nil)
    }

    // MARK: - JSON array

    private static func importJSON(at url: URL) -> ImportResult {
        guard let data = try? Data(contentsOf: url) else {
            return ImportResult(importedCount: 0, skippedCount: 0, errorMessage: "Could not read file.")
        }

        // Try as array of objects with textUpToCursor
        if let records = try? JSONDecoder().decode([CotypistRecord].self, from: data) {
            return importRecords(records)
        }

        // Try as array of strings (plain text snippets)
        if let texts = try? JSONDecoder().decode([String].self, from: data) {
            return importPlainTexts(texts)
        }

        return ImportResult(
            importedCount: 0,
            skippedCount: 0,
            errorMessage: "Could not parse JSON. Expected an array of objects with 'textUpToCursor' or an array of strings."
        )
    }

    // MARK: - JSONL (newline-delimited)

    private static func importJSONL(at url: URL) -> ImportResult {
        guard let data = try? Data(contentsOf: url) else {
            return ImportResult(importedCount: 0, skippedCount: 0, errorMessage: "Could not read file.")
        }

        let lines = data.split(separator: UInt8(ascii: "\n"))
        let decoder = JSONDecoder()
        var records: [CotypistRecord] = []

        for line in lines {
            if let record = try? decoder.decode(CotypistRecord.self, from: Data(line)) {
                records.append(record)
            }
        }

        if records.isEmpty {
            return ImportResult(importedCount: 0, skippedCount: 0, errorMessage: "No valid records found in JSONL file.")
        }

        return importRecords(records)
    }

    // MARK: - Shared

    private static func importRecords(_ records: [CotypistRecord]) -> ImportResult {
        let store = InputHistoryStore.shared
        var imported = 0
        var skipped = 0

        for record in records {
            let text = record.textUpToCursor
            guard text.count >= 10 else {
                skipped += 1
                continue
            }
            store.record(text: text, appBundleID: record.appBundleIdentifier, hadAcceptedCompletion: false)
            imported += 1
        }

        return ImportResult(importedCount: imported, skippedCount: skipped, errorMessage: nil)
    }

    private static func importPlainTexts(_ texts: [String]) -> ImportResult {
        let store = InputHistoryStore.shared
        var imported = 0
        var skipped = 0

        for text in texts {
            guard text.count >= 10 else {
                skipped += 1
                continue
            }
            store.record(text: text, appBundleID: nil, hadAcceptedCompletion: false)
            imported += 1
        }

        return ImportResult(importedCount: imported, skippedCount: skipped, errorMessage: nil)
    }
}

private struct CotypistRecord: Decodable {
    let textUpToCursor: String
    let appBundleIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case textUpToCursor
        case appBundleIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        textUpToCursor = try container.decode(String.self, forKey: .textUpToCursor)
        appBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .appBundleIdentifier)
    }
}
