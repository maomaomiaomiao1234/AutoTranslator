import Combine
import Foundation

enum TranslationHistoryKind: String, Codable, CaseIterable {
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

struct TranslationHistoryEntry: Identifiable, Codable, Equatable {
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
            return backend == "llm" ? "大模型" : "Google"
        }
    }
}

@MainActor
final class TranslationHistoryStore: ObservableObject {
    static let shared = TranslationHistoryStore()

    @Published private(set) var entries: [TranslationHistoryEntry]

    private let fileURL: URL
    private let maxRecentItems: Int

    init(fileURL: URL? = nil, maxRecentItems: Int = 500) {
        let resolvedURL = fileURL ?? Self.defaultFileURL()
        self.fileURL = resolvedURL
        self.maxRecentItems = max(1, maxRecentItems)
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

    private func persist() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            AppLog.error("保存翻译历史失败: \(error.localizedDescription)")
        }
    }

    private nonisolated static func loadEntries(from fileURL: URL) -> [TranslationHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode([TranslationHistoryEntry].self, from: data)
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
}
