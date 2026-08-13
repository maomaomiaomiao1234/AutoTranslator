import Combine
import Foundation

nonisolated enum TranslationHistoryKind: String, Codable, CaseIterable, Sendable {
    case translation
    case dictionary
    case systemDictionary

    var displayName: String {
        switch self {
        case .translation:
            return "翻译"
        case .dictionary:
            return "词典"
        case .systemDictionary:
            return "本地词典"
        }
    }
}

nonisolated struct TranslationHistoryImportResult: Equatable {
    let acceptedCount: Int
    let addedCount: Int
    let updatedCount: Int
}

nonisolated enum TranslationHistoryTransferError: LocalizedError {
    case invalidFile
    case noImportableEntries
    case historyUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "所选文件不是有效的 AutoTranslator 历史记录文件。"
        case .noImportableEntries:
            return "文件中没有可导入的历史记录。"
        case .historyUnavailable:
            return "历史数据库不可用，本次启动无法导入或导出历史记录。"
        }
    }
}

nonisolated struct TranslationHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var sourceText: String
    var translatedText: String
    var sourceLanguage: String
    var targetLanguage: String
    var backend: String
    var kind: TranslationHistoryKind
    var createdAt: Date
    var isFavorite: Bool

    var languageDescription: String {
        "\(Languages.name(for: sourceLanguage)) → \(Languages.name(for: targetLanguage))"
    }

    var backendDescription: String {
        switch kind {
        case .systemDictionary:
            return "系统词典"
        case .dictionary:
            return backend == "llm" ? "大模型词典" : "词典"
        case .translation:
            return TranslationBackend.shortName(backend)
        }
    }
}

@MainActor
final class TranslationHistoryStore: ObservableObject {
    static let shared = TranslationHistoryStore()

    /// 当前查询的一页。无论数据库里有多少收藏，常驻内存都受 pageSize 约束。
    @Published private(set) var entries: [TranslationHistoryEntry] = []
    @Published private(set) var totalEntryCount = 0
    @Published private(set) var favoriteEntryCount = 0
    @Published private(set) var filteredEntryCount = 0
    @Published private(set) var currentPage = 0
    /// 记录增删改的轻量通知；浮窗据此按 ID 查询当前记录，不依赖它是否在历史页中。
    @Published private(set) var revision = 0

    private let legacyFileURL: URL
    /// nil 表示连内存库都建不出来（SQLite 本身异常）：历史功能本会话整体停用，但应用不崩溃。
    private let database: HistoryDatabase?
    /// false = 磁盘库打开失败、当前会话跑在内存库（或完全停用）上，重启后本会话记录丢失。
    /// 此时绝不能迁移/改名旧版 history.json，否则下次启动磁盘库恢复时旧历史被静默丢弃。
    private(set) var isPersistent: Bool
    private let maxRecentItems: Int
    private let pageSize: Int
    private var searchText = ""
    private var favoritesOnly = false
    private var isPageLoadingActive = true

    init(fileURL: URL? = nil,
         maxRecentItems: Int = 500,
         writeDebounceInterval _: TimeInterval = 0.5,
         pageSize: Int = 100) {
        let resolvedLegacyURL = fileURL ?? Self.defaultFileURL()
        let databaseURL = resolvedLegacyURL
            .deletingPathExtension()
            .appendingPathExtension("sqlite3")
        var resolvedDatabase: HistoryDatabase?
        var resolvedIsPersistent = false
        do {
            resolvedDatabase = try HistoryDatabase(fileURL: databaseURL)
            resolvedIsPersistent = true
        } catch {
            AppLog.error("打开历史数据库失败，当前会话改用内存数据库: \(error.localizedDescription)")
            do {
                resolvedDatabase = try HistoryDatabase(fileURL: nil)
            } catch {
                AppLog.error("创建内存历史数据库也失败，本会话历史功能停用: \(error.localizedDescription)")
            }
        }

        self.legacyFileURL = resolvedLegacyURL
        self.database = resolvedDatabase
        self.isPersistent = resolvedIsPersistent
        self.maxRecentItems = max(1, maxRecentItems)
        self.pageSize = max(1, pageSize)

        if isPersistent {
            migrateLegacyHistoryIfNeeded()
        }
        do {
            try database?.trimNonFavorites(keeping: self.maxRecentItems)
        } catch {
            AppLog.error("裁剪历史记录失败: \(error.localizedDescription)")
        }
        refreshPage()
    }

    var pageCount: Int {
        max(1, (filteredEntryCount + pageSize - 1) / pageSize)
    }

    var canGoToPreviousPage: Bool { currentPage > 0 }
    var canGoToNextPage: Bool { currentPage + 1 < pageCount }

    func updateQuery(searchText: String, favoritesOnly: Bool) {
        guard self.searchText != searchText || self.favoritesOnly != favoritesOnly else { return }
        self.searchText = searchText
        self.favoritesOnly = favoritesOnly
        currentPage = 0
        refreshPage()
    }

    func goToPreviousPage() {
        guard canGoToPreviousPage else { return }
        currentPage -= 1
        refreshPage()
    }

    func goToNextPage() {
        guard canGoToNextPage else { return }
        currentPage += 1
        refreshPage()
    }

    func activatePageLoading() {
        guard !isPageLoadingActive else {
            refreshPage()
            return
        }
        isPageLoadingActive = true
        refreshPage()
    }

    func deactivatePageLoading() {
        isPageLoadingActive = false
        entries = []
    }

    @discardableResult
    func record(sourceText: String,
                translatedText: String,
                sourceLanguage: String,
                targetLanguage: String,
                backend: String,
                kind: TranslationHistoryKind,
                at date: Date = Date()) -> UUID? {
        let source = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !translation.isEmpty else { return nil }

        do {
            guard let database else { return nil }
            let previous = try database.entry(
                sourceText: source,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                backend: backend,
                kind: kind
            )
            let entry = TranslationHistoryEntry(
                id: previous?.id ?? UUID(),
                sourceText: source,
                translatedText: translation,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                backend: backend,
                kind: kind,
                createdAt: date,
                isFavorite: previous?.isFavorite ?? false
            )
            try database.save(entry)
            try database.trimNonFavorites(keeping: maxRecentItems)
            refreshAfterMutation()
            return entry.id
        } catch {
            AppLog.error("保存翻译历史失败: \(error.localizedDescription)")
            return nil
        }
    }

    func toggleFavorite(id: UUID) {
        do {
            guard let database, try database.toggleFavorite(id: id) else { return }
            try database.trimNonFavorites(keeping: maxRecentItems)
            refreshAfterMutation()
        } catch {
            AppLog.error("更新收藏状态失败: \(error.localizedDescription)")
        }
    }

    func delete(id: UUID) {
        do {
            guard let database, try database.delete(id: id) else { return }
            refreshAfterMutation()
        } catch {
            AppLog.error("删除历史记录失败: \(error.localizedDescription)")
        }
    }

    func clearNonFavorites() {
        do {
            guard let database, try database.clearNonFavorites() else { return }
            currentPage = 0
            refreshAfterMutation()
        } catch {
            AppLog.error("清空历史记录失败: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func exportEntries(favoritesOnly: Bool, to url: URL) throws -> Int {
        try exportEntries(favoritesOnly: favoritesOnly, format: .json, to: url)
    }

    @discardableResult
    func exportEntries(favoritesOnly: Bool, format: HistoryExportFormat, to url: URL) throws -> Int {
        guard let database else { throw TranslationHistoryTransferError.historyUnavailable }
        // 导出是用户主动发起的一次性操作；只在此时临时读取完整结果集。
        let entriesToExport = try database.fetchAll(favoritesOnly: favoritesOnly)
        let context = HistoryExportContext(favoritesOnly: favoritesOnly)
        let data: Data
        switch format {
        case .json:
            data = try Self.makeEncoder().encode(entriesToExport)
        case .markdown:
            data = Data(HistoryExportRenderer.markdown(for: entriesToExport, context: context).utf8)
        case .html:
            data = Data(HistoryExportRenderer.html(for: entriesToExport, context: context).utf8)
        case .pdf:
            data = try HistoryExportRenderer.pdfData(for: entriesToExport, context: context)
        }
        try data.write(to: url, options: [.atomic])
        return entriesToExport.count
    }

    @discardableResult
    func importEntries(from url: URL) throws -> TranslationHistoryImportResult {
        guard let database else { throw TranslationHistoryTransferError.historyUnavailable }
        let data = try Data(contentsOf: url)
        let decodedEntries: [TranslationHistoryEntry]
        do {
            decodedEntries = try Self.makeDecoder().decode([TranslationHistoryEntry].self, from: data)
        } catch {
            throw TranslationHistoryTransferError.invalidFile
        }

        let importedEntries = decodedEntries.compactMap(Self.normalized)
        guard !importedEntries.isEmpty else {
            throw TranslationHistoryTransferError.noImportableEntries
        }

        let existingEntries = try database.fetchAll()
        let mergeResult = Self.merging(
            existingEntries: existingEntries,
            importedEntries: Self.mergeDuplicateImports(importedEntries)
        )
        try database.replaceAll(with: mergeResult.entries)
        try database.trimNonFavorites(keeping: maxRecentItems)
        currentPage = 0
        refreshAfterMutation()
        return TranslationHistoryImportResult(
            acceptedCount: importedEntries.count,
            addedCount: mergeResult.addedCount,
            updatedCount: mergeResult.updatedCount
        )
    }

    func entry(id: UUID?) -> TranslationHistoryEntry? {
        guard let id, let database else { return nil }
        do {
            return try database.entry(id: id)
        } catch {
            AppLog.error("读取历史记录失败: \(error.localizedDescription)")
            return entries.first { $0.id == id }
        }
    }

    /// SQLite 写入是事务性的，不再有待刷新的整份 JSON 快照；退出时只做 WAL checkpoint。
    func flush() {
        database?.checkpoint()
    }

    private func refreshAfterMutation() {
        refreshPage()
        revision &+= 1
    }

    private func refreshPage() {
        guard let database else {
            entries = []
            return
        }
        // 历史窗口关闭（分页停用）时跳过全部 COUNT 与分页查询：这些数值只有
        // 历史窗口在读，划词高频写入路径不必每条译文多跑 4 条 SQL（其中搜索态
        // COUNT 是 LIKE 全表扫描）。窗口重新打开时 activatePageLoading 会全量刷新。
        guard isPageLoadingActive else {
            if !entries.isEmpty { entries = [] }
            return
        }
        do {
            totalEntryCount = try database.count()
            favoriteEntryCount = try database.count(favoritesOnly: true)
            filteredEntryCount = try database.count(
                searchText: searchText,
                favoritesOnly: favoritesOnly
            )
            let lastPage = max(0, (filteredEntryCount - 1) / pageSize)
            currentPage = min(currentPage, lastPage)
            entries = try database.fetchPage(
                searchText: searchText,
                favoritesOnly: favoritesOnly,
                limit: pageSize,
                offset: currentPage * pageSize
            )
        } catch {
            AppLog.error("刷新历史分页失败: \(error.localizedDescription)")
        }
    }

    private func migrateLegacyHistoryIfNeeded() {
        // 调用方已确保只在持久化磁盘库上执行。回退内存库时迁移等于把旧 JSON 灌进
        // 一次性数据库再改名原文件，下次启动磁盘库恢复后旧历史就静默消失了。
        guard isPersistent, let database else { return }
        do {
            guard try !database.hasCompletedLegacyMigration() else { return }
            guard FileManager.default.fileExists(atPath: legacyFileURL.path) else {
                try database.markLegacyMigrationCompleted()
                return
            }

            let data = try Data(contentsOf: legacyFileURL)
            let decoded = try Self.makeDecoder().decode([TranslationHistoryEntry].self, from: data)
            let imported = Self.mergeDuplicateImports(decoded.compactMap(Self.normalized))
            let existing = try database.fetchAll()
            let mergeResult = Self.merging(existingEntries: existing, importedEntries: imported)
            try database.replaceAll(with: mergeResult.entries)
            try database.markLegacyMigrationCompleted()
            preserveLegacyFileAsBackup()
            AppLog.debug("已迁移历史 JSON 到 SQLite entries=\(mergeResult.entries.count)")
        } catch {
            AppLog.error("迁移旧版历史 JSON 失败，将保留原文件稍后重试: \(error.localizedDescription)")
        }
    }

    private func preserveLegacyFileAsBackup() {
        let backupURL = legacyFileURL.appendingPathExtension("migrated-backup")
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        do {
            try FileManager.default.moveItem(at: legacyFileURL, to: backupURL)
        } catch {
            // 数据已经安全写入数据库；备份改名失败时保留原 JSON，不影响后续启动。
            AppLog.error("旧版历史 JSON 备份改名失败: \(error.localizedDescription)")
        }
    }

    private nonisolated static func defaultFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoTranslator", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    fileprivate nonisolated static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private nonisolated static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private nonisolated static func normalized(_ entry: TranslationHistoryEntry) -> TranslationHistoryEntry? {
        let sourceText = entry.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let translatedText = entry.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceLanguage = entry.sourceLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetLanguage = entry.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        let backend = entry.backend.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty,
              !translatedText.isEmpty,
              !sourceLanguage.isEmpty,
              !targetLanguage.isEmpty,
              !backend.isEmpty else {
            return nil
        }
        return TranslationHistoryEntry(
            id: entry.id,
            sourceText: sourceText,
            translatedText: translatedText,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            backend: backend,
            kind: entry.kind,
            createdAt: entry.createdAt,
            isFavorite: entry.isFavorite
        )
    }

    private nonisolated static func mergeDuplicateImports(
        _ importedEntries: [TranslationHistoryEntry]
    ) -> [TranslationHistoryEntry] {
        var entriesByIdentity: [HistoryEntryIdentity: TranslationHistoryEntry] = [:]
        for entry in importedEntries {
            let identity = identity(for: entry)
            guard let existingEntry = entriesByIdentity[identity] else {
                entriesByIdentity[identity] = entry
                continue
            }
            entriesByIdentity[identity] = merged(existing: existingEntry, imported: entry)
        }
        return entriesByIdentity.values.sorted { $0.createdAt > $1.createdAt }
    }

    private nonisolated static func merged(
        existing: TranslationHistoryEntry,
        imported: TranslationHistoryEntry
    ) -> TranslationHistoryEntry {
        let newerEntry = imported.createdAt > existing.createdAt ? imported : existing
        return TranslationHistoryEntry(
            id: existing.id,
            sourceText: newerEntry.sourceText,
            translatedText: newerEntry.translatedText,
            sourceLanguage: newerEntry.sourceLanguage,
            targetLanguage: newerEntry.targetLanguage,
            backend: newerEntry.backend,
            kind: newerEntry.kind,
            createdAt: newerEntry.createdAt,
            isFavorite: existing.isFavorite || imported.isFavorite
        )
    }

    private nonisolated static func identity(for entry: TranslationHistoryEntry) -> HistoryEntryIdentity {
        HistoryEntryIdentity(
            sourceText: entry.sourceText,
            sourceLanguage: entry.sourceLanguage,
            targetLanguage: entry.targetLanguage,
            backend: entry.backend,
            kind: entry.kind.rawValue
        )
    }

    private nonisolated static func merging(
        existingEntries: [TranslationHistoryEntry],
        importedEntries: [TranslationHistoryEntry]
    ) -> HistoryMergeResult {
        var mergedEntries = existingEntries
        var existingIndexByIdentity: [HistoryEntryIdentity: Int] = [:]
        for (index, entry) in mergedEntries.enumerated() {
            existingIndexByIdentity[identity(for: entry)] = index
        }
        var usedIDs = Set(mergedEntries.map(\.id))
        var addedCount = 0
        var updatedCount = 0

        for importedEntry in importedEntries {
            let importedIdentity = identity(for: importedEntry)
            if let index = existingIndexByIdentity[importedIdentity] {
                let existingEntry = mergedEntries[index]
                let mergedEntry = merged(existing: existingEntry, imported: importedEntry)
                if mergedEntry != existingEntry {
                    mergedEntries[index] = mergedEntry
                    updatedCount += 1
                }
                continue
            }

            var entry = importedEntry
            while usedIDs.contains(entry.id) {
                entry = TranslationHistoryEntry(
                    id: UUID(),
                    sourceText: entry.sourceText,
                    translatedText: entry.translatedText,
                    sourceLanguage: entry.sourceLanguage,
                    targetLanguage: entry.targetLanguage,
                    backend: entry.backend,
                    kind: entry.kind,
                    createdAt: entry.createdAt,
                    isFavorite: entry.isFavorite
                )
            }
            usedIDs.insert(entry.id)
            existingIndexByIdentity[importedIdentity] = mergedEntries.count
            mergedEntries.append(entry)
            addedCount += 1
        }

        return HistoryMergeResult(
            entries: mergedEntries.sorted { $0.createdAt > $1.createdAt },
            addedCount: addedCount,
            updatedCount: updatedCount
        )
    }
}

private nonisolated struct HistoryEntryIdentity: Hashable {
    let sourceText: String
    let sourceLanguage: String
    let targetLanguage: String
    let backend: String
    let kind: String
}

private nonisolated struct HistoryMergeResult {
    let entries: [TranslationHistoryEntry]
    let addedCount: Int
    let updatedCount: Int
}
