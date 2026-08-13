import Foundation
import SQLite3

/// SQLite-backed history persistence. The UI only asks this type for one bounded page;
/// full reads are reserved for explicit import/export operations.
final class HistoryDatabase {
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var connection: OpaquePointer?
    /// 按 SQL 文本缓存 prepared statement。高频语句（record 路径、导入循环的
    /// save）此前每次现场 prepare，导入万条即万次解析同一句 SQL。
    /// SQL 变体有限（查询 × 过滤组合），缓存天然有界。
    private var cachedStatements: [String: OpaquePointer] = [:]

    init(fileURL: URL?) throws {
        if let fileURL {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }

        let path = fileURL?.path ?? ":memory:"
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "无法创建 SQLite 连接"
            if let database { sqlite3_close(database) }
            throw HistoryDatabaseError.sqlite(message)
        }

        connection = database
        sqlite3_busy_timeout(database, 2_000)

        do {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = NORMAL")
            try createSchema()
        } catch {
            sqlite3_close(database)
            connection = nil
            throw error
        }
    }

    deinit {
        for statement in cachedStatements.values {
            sqlite3_finalize(statement)
        }
        if let connection {
            sqlite3_close(connection)
        }
    }

    func hasCompletedLegacyMigration() throws -> Bool {
        let statement = try prepare("SELECT value FROM history_metadata WHERE key = ? LIMIT 1")
        defer { reset(statement) }
        bind("legacy_json_migrated", at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return columnText(statement, at: 0) == "1"
    }

    func markLegacyMigrationCompleted() throws {
        let statement = try prepare(
            """
            INSERT INTO history_metadata(key, value) VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
        defer { reset(statement) }
        bind("legacy_json_migrated", at: 1, in: statement)
        bind("1", at: 2, in: statement)
        try stepDone(statement)
    }

    func entry(id: UUID) throws -> TranslationHistoryEntry? {
        let statement = try prepare(
            """
            SELECT id, source_text, translated_text, source_language, target_language,
                   backend, entry_kind, created_at, is_favorite
            FROM history_entries WHERE id = ? LIMIT 1
            """
        )
        defer { reset(statement) }
        bind(id.uuidString, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return decodeEntry(statement)
    }

    func entry(sourceText: String,
               sourceLanguage: String,
               targetLanguage: String,
               backend: String,
               kind: TranslationHistoryKind) throws -> TranslationHistoryEntry? {
        let statement = try prepare(
            """
            SELECT id, source_text, translated_text, source_language, target_language,
                   backend, entry_kind, created_at, is_favorite
            FROM history_entries
            WHERE source_text = ? AND source_language = ? AND target_language = ?
              AND backend = ? AND entry_kind = ?
            LIMIT 1
            """
        )
        defer { reset(statement) }
        for (offset, value) in [
            sourceText,
            sourceLanguage,
            targetLanguage,
            backend,
            kind.rawValue,
        ].enumerated() {
            bind(value, at: Int32(offset + 1), in: statement)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return decodeEntry(statement)
    }

    func fetchPage(searchText: String,
                   favoritesOnly: Bool,
                   limit: Int,
                   offset: Int) throws -> [TranslationHistoryEntry] {
        let filter = makeFilter(searchText: searchText, favoritesOnly: favoritesOnly)
        let statement = try prepare(
            """
            SELECT id, source_text, translated_text, source_language, target_language,
                   backend, entry_kind, created_at, is_favorite
            FROM history_entries
            \(filter.clause)
            ORDER BY created_at DESC, rowid DESC
            LIMIT ? OFFSET ?
            """
        )
        defer { reset(statement) }
        bind(filter.bindings, in: statement)
        let nextIndex = Int32(filter.bindings.count + 1)
        sqlite3_bind_int64(statement, nextIndex, Int64(max(1, limit)))
        sqlite3_bind_int64(statement, nextIndex + 1, Int64(max(0, offset)))
        return try readEntries(statement)
    }

    func fetchAll(favoritesOnly: Bool = false) throws -> [TranslationHistoryEntry] {
        let whereClause = favoritesOnly ? "WHERE is_favorite = 1" : ""
        let statement = try prepare(
            """
            SELECT id, source_text, translated_text, source_language, target_language,
                   backend, entry_kind, created_at, is_favorite
            FROM history_entries
            \(whereClause)
            ORDER BY created_at DESC, rowid DESC
            """
        )
        defer { reset(statement) }
        return try readEntries(statement)
    }

    func count(searchText: String = "", favoritesOnly: Bool = false) throws -> Int {
        let filter = makeFilter(searchText: searchText, favoritesOnly: favoritesOnly)
        let statement = try prepare("SELECT COUNT(*) FROM history_entries \(filter.clause)")
        defer { reset(statement) }
        bind(filter.bindings, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw currentError()
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func save(_ entry: TranslationHistoryEntry) throws {
        let statement = try prepare(
            """
            INSERT INTO history_entries(
                id, source_text, translated_text, source_language, target_language,
                backend, entry_kind, created_at, is_favorite
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_text, source_language, target_language, backend, entry_kind)
            DO UPDATE SET
                translated_text = excluded.translated_text,
                created_at = excluded.created_at,
                is_favorite = excluded.is_favorite
            """
        )
        defer { reset(statement) }
        let textValues = [
            entry.id.uuidString,
            entry.sourceText,
            entry.translatedText,
            entry.sourceLanguage,
            entry.targetLanguage,
            entry.backend,
            entry.kind.rawValue,
        ]
        bind(textValues, in: statement)
        sqlite3_bind_double(statement, 8, entry.createdAt.timeIntervalSince1970)
        sqlite3_bind_int(statement, 9, entry.isFavorite ? 1 : 0)
        try stepDone(statement)
    }

    func replaceAll(with entries: [TranslationHistoryEntry]) throws {
        try transaction {
            try execute("DELETE FROM history_entries")
            for entry in entries {
                try save(entry)
            }
        }
    }

    @discardableResult
    func toggleFavorite(id: UUID) throws -> Bool {
        let statement = try prepare(
            """
            UPDATE history_entries
            SET is_favorite = CASE is_favorite WHEN 0 THEN 1 ELSE 0 END
            WHERE id = ?
            """
        )
        defer { reset(statement) }
        bind(id.uuidString, at: 1, in: statement)
        try stepDone(statement)
        return sqlite3_changes(connection) > 0
    }

    @discardableResult
    func delete(id: UUID) throws -> Bool {
        let statement = try prepare("DELETE FROM history_entries WHERE id = ?")
        defer { reset(statement) }
        bind(id.uuidString, at: 1, in: statement)
        try stepDone(statement)
        return sqlite3_changes(connection) > 0
    }

    @discardableResult
    func clearNonFavorites() throws -> Bool {
        try execute("DELETE FROM history_entries WHERE is_favorite = 0")
        return sqlite3_changes(connection) > 0
    }

    func trimNonFavorites(keeping limit: Int) throws {
        let statement = try prepare(
            """
            DELETE FROM history_entries
            WHERE id IN (
                SELECT id FROM history_entries
                WHERE is_favorite = 0
                ORDER BY created_at DESC, rowid DESC
                LIMIT -1 OFFSET ?
            )
            """
        )
        defer { reset(statement) }
        sqlite3_bind_int64(statement, 1, Int64(max(1, limit)))
        try stepDone(statement)
    }

    func checkpoint() {
        try? execute("PRAGMA wal_checkpoint(PASSIVE)")
    }

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS history_entries(
                id TEXT PRIMARY KEY NOT NULL,
                source_text TEXT NOT NULL,
                translated_text TEXT NOT NULL,
                source_language TEXT NOT NULL,
                target_language TEXT NOT NULL,
                backend TEXT NOT NULL,
                entry_kind TEXT NOT NULL,
                created_at REAL NOT NULL,
                is_favorite INTEGER NOT NULL DEFAULT 0
            )
            """
        )
        try execute(
            """
            CREATE UNIQUE INDEX IF NOT EXISTS history_identity_index
            ON history_entries(source_text, source_language, target_language, backend, entry_kind)
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS history_created_index
            ON history_entries(created_at DESC)
            """
        )
        try execute(
            """
            CREATE INDEX IF NOT EXISTS history_favorite_created_index
            ON history_entries(is_favorite, created_at DESC)
            """
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS history_metadata(
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """
        )
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func makeFilter(searchText: String,
                            favoritesOnly: Bool) -> (clause: String, bindings: [String]) {
        var conditions: [String] = []
        var bindings: [String] = []
        if favoritesOnly {
            conditions.append("is_favorite = 1")
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let pattern = "%\(escapedLikePattern(query))%"
            conditions.append(
                """
                (source_text LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR translated_text LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR source_language LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR target_language LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR backend LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR entry_kind LIKE ? ESCAPE '\\' COLLATE NOCASE
                 OR (
                    CASE source_language
                        WHEN 'auto' THEN '自动检测'
                        WHEN 'zh-CN' THEN '中文简体'
                        WHEN 'en' THEN '英语'
                        WHEN 'ja' THEN '日语'
                        WHEN 'ko' THEN '韩语'
                        WHEN 'fr' THEN '法语'
                        WHEN 'de' THEN '德语'
                        WHEN 'ru' THEN '俄语'
                        ELSE source_language
                    END || ' ' ||
                    CASE target_language
                        WHEN 'zh-CN' THEN '中文简体'
                        WHEN 'en' THEN '英语'
                        WHEN 'ja' THEN '日语'
                        WHEN 'ko' THEN '韩语'
                        WHEN 'fr' THEN '法语'
                        WHEN 'de' THEN '德语'
                        WHEN 'ru' THEN '俄语'
                        ELSE target_language
                    END || ' ' ||
                    CASE backend
                        WHEN 'llm' THEN '大模型 大模型翻译 大模型词典'
                        WHEN 'apple' THEN '系统 系统翻译'
                        ELSE '谷歌 Google 谷歌翻译 词典'
                    END || ' ' ||
                    CASE entry_kind
                        WHEN 'dictionary' THEN '词典'
                        WHEN 'systemDictionary' THEN '本地词典 系统词典'
                        ELSE '翻译'
                    END
                 ) LIKE ? ESCAPE '\\' COLLATE NOCASE)
                """
            )
            bindings.append(contentsOf: Array(repeating: pattern, count: 7))
        }

        return (
            conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND "),
            bindings
        )
    }

    private func escapedLikePattern(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func readEntries(_ statement: OpaquePointer) throws -> [TranslationHistoryEntry] {
        var entries: [TranslationHistoryEntry] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let entry = decodeEntry(statement) {
                    entries.append(entry)
                }
            case SQLITE_DONE:
                return entries
            default:
                throw currentError()
            }
        }
    }

    private func decodeEntry(_ statement: OpaquePointer) -> TranslationHistoryEntry? {
        guard let id = UUID(uuidString: columnText(statement, at: 0)),
              let kind = TranslationHistoryKind(rawValue: columnText(statement, at: 6)) else {
            return nil
        }
        return TranslationHistoryEntry(
            id: id,
            sourceText: columnText(statement, at: 1),
            translatedText: columnText(statement, at: 2),
            sourceLanguage: columnText(statement, at: 3),
            targetLanguage: columnText(statement, at: 4),
            backend: columnText(statement, at: 5),
            kind: kind,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
            isFavorite: sqlite3_column_int(statement, 8) != 0
        )
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let connection else { throw HistoryDatabaseError.sqlite("数据库连接已关闭") }
        if let cached = cachedStatements[sql] { return cached }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw currentError()
        }
        cachedStatements[sql] = statement
        return statement
    }

    /// 缓存语句用完必须复位（替代原先的 finalize），否则下次执行携带旧绑定与游标。
    private func reset(_ statement: OpaquePointer) {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    private func execute(_ sql: String) throws {
        guard let connection else { throw HistoryDatabaseError.sqlite("数据库连接已关闭") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(connection, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(connection))
            sqlite3_free(errorMessage)
            throw HistoryDatabaseError.sqlite(message)
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw currentError()
        }
    }

    private func bind(_ values: [String], in statement: OpaquePointer) {
        for (offset, value) in values.enumerated() {
            bind(value, at: Int32(offset + 1), in: statement)
        }
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.transientDestructor)
    }

    private func columnText(_ statement: OpaquePointer, at index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private func currentError() -> HistoryDatabaseError {
        guard let connection else { return .sqlite("数据库连接已关闭") }
        return .sqlite(String(cString: sqlite3_errmsg(connection)))
    }
}

private enum HistoryDatabaseError: LocalizedError {
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message):
            return "历史数据库错误：\(message)"
        }
    }
}
