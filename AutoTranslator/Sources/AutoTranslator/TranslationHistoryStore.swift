import Combine
import Foundation

enum TranslationHistoryKind: String, Codable, CaseIterable, Sendable {
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

struct TranslationHistoryImportResult: Equatable {
    let acceptedCount: Int
    let addedCount: Int
    let updatedCount: Int
}

enum TranslationHistoryTransferError: LocalizedError {
    case invalidFile
    case noImportableEntries

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "所选文件不是有效的 AutoTranslator 历史记录文件。"
        case .noImportableEntries:
            return "文件中没有可导入的历史记录。"
        }
    }
}

struct TranslationHistoryEntry: Identifiable, Codable, Equatable, Sendable {
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

    @Published private(set) var entries: [TranslationHistoryEntry]

    private let fileURL: URL
    private let maxRecentItems: Int
    private let writer: HistoryFileWriter
    private let writeDebounceInterval: TimeInterval

    init(fileURL: URL? = nil, maxRecentItems: Int = 500, writeDebounceInterval: TimeInterval = 0.5) {
        let resolvedURL = fileURL ?? Self.defaultFileURL()
        self.fileURL = resolvedURL
        self.maxRecentItems = max(1, maxRecentItems)
        self.writeDebounceInterval = max(0, writeDebounceInterval)
        self.writer = HistoryFileWriter(fileURL: resolvedURL)
        entries = Self.loadEntries(from: resolvedURL)
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

        let identityIndex = entries.firstIndex {
            $0.sourceText == source
                && $0.sourceLanguage == sourceLanguage
                && $0.targetLanguage == targetLanguage
                && $0.backend == backend
                && $0.kind == kind
        }

        let entry: TranslationHistoryEntry
        if let identityIndex {
            let previous = entries.remove(at: identityIndex)
            entry = TranslationHistoryEntry(
                id: previous.id,
                sourceText: source,
                translatedText: translation,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                backend: backend,
                kind: kind,
                createdAt: date,
                isFavorite: previous.isFavorite
            )
        } else {
            entry = TranslationHistoryEntry(
                id: UUID(),
                sourceText: source,
                translatedText: translation,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                backend: backend,
                kind: kind,
                createdAt: date,
                isFavorite: false
            )
        }

        entries.insert(entry, at: 0)
        trimRecentItemsIfNeeded()
        persist()
        return entry.id
    }

    func toggleFavorite(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isFavorite.toggle()
        persist()
    }

    func delete(id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        persist()
    }

    func clearNonFavorites() {
        guard entries.contains(where: { !$0.isFavorite }) else { return }
        entries.removeAll { !$0.isFavorite }
        persist()
    }

    @discardableResult
    func exportEntries(favoritesOnly: Bool, to url: URL) throws -> Int {
        try exportEntries(favoritesOnly: favoritesOnly, format: .json, to: url)
    }

    @discardableResult
    func exportEntries(favoritesOnly: Bool, format: HistoryExportFormat, to url: URL) throws -> Int {
        let entriesToExport = favoritesOnly
            ? entries.filter(\.isFavorite)
            : entries
        let data: Data
        switch format {
        case .json:
            data = try Self.makeEncoder().encode(entriesToExport)
        case .markdown:
            data = Data(HistoryExportRenderer.markdown(for: entriesToExport).utf8)
        case .html:
            data = Data(HistoryExportRenderer.html(for: entriesToExport).utf8)
        case .pdf:
            data = try HistoryExportRenderer.pdfData(for: entriesToExport)
        }
        try data.write(to: url, options: [.atomic])
        return entriesToExport.count
    }

    @discardableResult
    func importEntries(from url: URL) throws -> TranslationHistoryImportResult {
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

        let mergedImportedEntries = Self.mergeDuplicateImports(importedEntries)
        var mergedEntries = entries
        var existingIndexByIdentity: [HistoryEntryIdentity: Int] = [:]
        for (index, entry) in mergedEntries.enumerated() {
            existingIndexByIdentity[Self.identity(for: entry)] = index
        }
        var usedIDs = Set(mergedEntries.map(\.id))
        var addedCount = 0
        var updatedCount = 0

        for importedEntry in mergedImportedEntries {
            let identity = Self.identity(for: importedEntry)
            if let index = existingIndexByIdentity[identity] {
                let existingEntry = mergedEntries[index]
                let mergedEntry = Self.merged(existing: existingEntry, imported: importedEntry)
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
            existingIndexByIdentity[identity] = mergedEntries.count
            mergedEntries.append(entry)
            addedCount += 1
        }

        entries = mergedEntries.sorted { $0.createdAt > $1.createdAt }
        trimRecentItemsIfNeeded()
        persist()
        return TranslationHistoryImportResult(
            acceptedCount: importedEntries.count,
            addedCount: addedCount,
            updatedCount: updatedCount
        )
    }

    func entry(id: UUID?) -> TranslationHistoryEntry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }

    private func trimRecentItemsIfNeeded() {
        var retainedNonFavorites = 0
        entries = entries.filter { entry in
            if entry.isFavorite { return true }
            retainedNonFavorites += 1
            return retainedNonFavorites <= maxRecentItems
        }
    }

    /// 内存中的 entries 立即更新（驱动 UI），磁盘写入交给后台串行 writer，
    /// 并对突发的连续写入做合并去抖，避免每次划词都在主线程上整文件编码+写盘。
    private func persist() {
        writer.schedule(entries, debounce: writeDebounceInterval)
    }

    /// 同步刷新待写的历史到磁盘。App 退出前调用以确保不丢最近记录；测试中用于在回读文件前落盘。
    func flush() {
        writer.flush()
    }

    private nonisolated static func loadEntries(from fileURL: URL) -> [TranslationHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try makeDecoder().decode([TranslationHistoryEntry].self, from: data)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            AppLog.error("读取翻译历史失败，将从空历史开始: \(error.localizedDescription)")
            return []
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
}

private nonisolated struct HistoryEntryIdentity: Hashable {
    let sourceText: String
    let sourceLanguage: String
    let targetLanguage: String
    let backend: String
    let kind: String
}

/// 后台串行历史写入器：合并去抖突发写入，把 JSON 编码与磁盘写入移出主线程。
/// 待写快照在锁内更新，因此连续多次 schedule 只会写出最后一次；flush() 同步落盘。
private final class HistoryFileWriter: @unchecked Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.autotranslator.history-writer", qos: .utility)
    private let lock = NSLock()
    private var pendingSnapshot: [TranslationHistoryEntry]?
    private var isWriteScheduled = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// 安排一次（去抖动的）写盘。debounce 期间到来的多次调用会合并为一次，只写最后一次快照。
    func schedule(_ snapshot: [TranslationHistoryEntry], debounce: TimeInterval) {
        lock.lock()
        pendingSnapshot = snapshot
        let needsSchedule = !isWriteScheduled
        if needsSchedule { isWriteScheduled = true }
        lock.unlock()

        guard needsSchedule else { return }
        if debounce <= 0 {
            queue.async { [weak self] in self?.drain() }
        } else {
            queue.asyncAfter(deadline: .now() + debounce) { [weak self] in self?.drain() }
        }
    }

    /// 同步写出当前待写快照（若有）。用于 App 退出与测试回读前确保已落盘。
    func flush() {
        queue.sync { drain() }
    }

    private func drain() {
        lock.lock()
        let snapshot = pendingSnapshot
        pendingSnapshot = nil
        isWriteScheduled = false
        lock.unlock()

        guard let snapshot else { return }
        write(snapshot)
    }

    private func write(_ entries: [TranslationHistoryEntry]) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try TranslationHistoryStore.makeEncoder().encode(entries)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            AppLog.error("保存翻译历史失败: \(error.localizedDescription)")
        }
    }
}
