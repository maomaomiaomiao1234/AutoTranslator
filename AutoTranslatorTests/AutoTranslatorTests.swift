//
//  AutoTranslatorTests.swift
//  AutoTranslatorTests
//
//  Created by hang w on 12/6/26.
//

import AppKit
import Foundation
import Testing
@testable import AutoTranslator

@MainActor
struct DesignSystemColorTests {
    @Test
    func mutedTextMaintainsReadableContrastInBothAppearances() {
        let lightText = components(of: TEXT_MUTED, appearance: .aqua)
        let lightBackground = components(of: PANEL_BOTTOM, appearance: .aqua)
        let darkText = components(of: TEXT_MUTED, appearance: .darkAqua)
        let darkBackground = components(of: PANEL_BOTTOM, appearance: .darkAqua)

        #expect(contrastRatio(lightText, lightBackground) >= 4.5)
        #expect(contrastRatio(darkText, darkBackground) >= 4.5)
        #expect(lightText.red < darkText.red)
    }

    private func components(
        of color: NSColor,
        appearance name: NSAppearance.Name
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        var result: (red: CGFloat, green: CGFloat, blue: CGFloat) = (0, 0, 0)
        let appearance = NSAppearance(named: name)!
        appearance.performAsCurrentDrawingAppearance {
            guard let resolved = color.usingColorSpace(.sRGB) else { return }
            result = (resolved.redComponent, resolved.greenComponent, resolved.blueComponent)
        }
        return result
    }

    private func contrastRatio(
        _ first: (red: CGFloat, green: CGFloat, blue: CGFloat),
        _ second: (red: CGFloat, green: CGFloat, blue: CGFloat)
    ) -> CGFloat {
        let firstLuminance = relativeLuminance(first)
        let secondLuminance = relativeLuminance(second)
        return (max(firstLuminance, secondLuminance) + 0.05)
            / (min(firstLuminance, secondLuminance) + 0.05)
    }

    private func relativeLuminance(
        _ color: (red: CGFloat, green: CGFloat, blue: CGFloat)
    ) -> CGFloat {
        func linearize(_ component: CGFloat) -> CGFloat {
            if component <= 0.04045 {
                return component / 12.92
            }
            return CGFloat(pow(Double((component + 0.055) / 1.055), 2.4))
        }

        return 0.2126 * linearize(color.red)
            + 0.7152 * linearize(color.green)
            + 0.0722 * linearize(color.blue)
    }
}

struct LanguageHeuristicsTests {
    @Test
    func autoDetectedChineseUsesEnglishWhenTargetIsDefaultChinese() {
        let target = LanguageHeuristics.effectiveTargetLanguage(
            sourceLanguage: "auto",
            configuredTargetLanguage: "zh-CN",
            text: "苹果"
        )

        #expect(target == "en")
    }

    @Test
    func autoDetectedJapaneseScreenshotKeepsSimplifiedChineseTarget() {
        let screenshotText = """
        詳細については iTunes サポート
        www.apple.com/support/itunes/
        ww/へご連絡ください。
        OK
        Apple Account の設定には数分かかる場合があります。
        """

        let target = LanguageHeuristics.effectiveTargetLanguage(
            sourceLanguage: "auto",
            configuredTargetLanguage: "zh-CN",
            text: screenshotText
        )

        #expect(LanguageHeuristics.containsChinese(screenshotText))
        #expect(!LanguageHeuristics.isLikelyChinese(screenshotText))
        #expect(target == "zh-CN")
    }

    @Test
    func nonChineseOrExplicitLanguageKeepsConfiguredTarget() {
        #expect(LanguageHeuristics.effectiveTargetLanguage(
            sourceLanguage: "auto",
            configuredTargetLanguage: "zh-CN",
            text: "apple"
        ) == "zh-CN")
        #expect(LanguageHeuristics.effectiveTargetLanguage(
            sourceLanguage: "zh-CN",
            configuredTargetLanguage: "zh-CN",
            text: "苹果"
        ) == "zh-CN")
        #expect(LanguageHeuristics.effectiveTargetLanguage(
            sourceLanguage: "auto",
            configuredTargetLanguage: "ja",
            text: "苹果"
        ) == "ja")
    }

    @Test
    func chineseDictionaryEntryAlwaysUsesEnglishTarget() {
        #expect(LanguageHeuristics.effectiveDictionaryTargetLanguage(
            sourceLanguage: "zh-CN",
            configuredTargetLanguage: "ja",
            word: "翻译"
        ) == "en")
        #expect(LanguageHeuristics.effectiveDictionaryTargetLanguage(
            sourceLanguage: "auto",
            configuredTargetLanguage: "zh-CN",
            word: "translation"
        ) == "zh-CN")
    }

    @Test
    func chineseTextRequiresARealSystemDictionaryEntryForDictionaryMode() {
        #expect(!LanguageHeuristics.shouldUseDictionaryMode(
            for: "请求失败时保留系统词典结果",
            systemDefinitionAvailable: false
        ))
        #expect(LanguageHeuristics.shouldUseDictionaryMode(
            for: "翻译",
            systemDefinitionAvailable: true
        ))
        #expect(LanguageHeuristics.shouldUseDictionaryMode(
            for: "translation",
            systemDefinitionAvailable: false
        ))
    }
}

struct SystemDictionaryTests {
    @Test
    func englishTranslationIsInsertedAfterDictionaryTitle() {
        let result = SystemDictionary.definition(
            "翻译\n这是将内容从一种语言转换成另一种语言。",
            addingEnglishTranslation: "translate; translation"
        )

        #expect(result == "翻译\n英文翻译：translate; translation\n这是将内容从一种语言转换成另一种语言。")
    }
}

@MainActor
@Suite(.serialized)
struct TranslationHistoryStoreTests {
    @Test
    func repeatedTranslationUpdatesExistingEntryAndPreservesFavorite() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let firstDate = Date(timeIntervalSince1970: 1_000)
        let updatedDate = Date(timeIntervalSince1970: 2_000)
        let firstID = fixture.store.record(
            sourceText: "hello",
            translatedText: "你好",
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            backend: "llm",
            kind: .translation,
            at: firstDate
        )

        #expect(firstID != nil)
        fixture.store.toggleFavorite(id: try #require(firstID))

        let updatedID = fixture.store.record(
            sourceText: "hello",
            translatedText: "您好",
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            backend: "llm",
            kind: .translation,
            at: updatedDate
        )

        #expect(updatedID == firstID)
        #expect(fixture.store.entries.count == 1)
        #expect(fixture.store.entries[0].translatedText == "您好")
        #expect(fixture.store.entries[0].createdAt == updatedDate)
        #expect(fixture.store.entries[0].isFavorite)
    }

    @Test
    func capacityLimitKeepsFavoritesAndPersistsEntries() throws {
        let fixture = try makeFixture(maxRecentItems: 1)
        defer { fixture.cleanup() }

        let favoriteID = fixture.store.record(
            sourceText: "favorite",
            translatedText: "收藏",
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            backend: "google",
            kind: .translation,
            at: Date(timeIntervalSince1970: 1_000)
        )
        fixture.store.toggleFavorite(id: try #require(favoriteID))

        fixture.store.record(
            sourceText: "older",
            translatedText: "较旧",
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            backend: "google",
            kind: .translation,
            at: Date(timeIntervalSince1970: 2_000)
        )
        fixture.store.record(
            sourceText: "newest",
            translatedText: "最新",
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            backend: "google",
            kind: .translation,
            at: Date(timeIntervalSince1970: 3_000)
        )

        #expect(fixture.store.entries.count == 2)
        #expect(fixture.store.entries.contains(where: { $0.id == favoriteID && $0.isFavorite }))
        #expect(fixture.store.entries.contains(where: { $0.sourceText == "newest" }))
        #expect(!fixture.store.entries.contains(where: { $0.sourceText == "older" }))

        fixture.store.flush()
        let reloaded = TranslationHistoryStore(fileURL: fixture.fileURL, maxRecentItems: 1)
        #expect(reloaded.entries == fixture.store.entries)
    }

    @Test
    func clearingHistoryPreservesFavorites() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let favoriteID = fixture.store.record(
            sourceText: "keep",
            translatedText: "保留",
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            backend: "llm",
            kind: .dictionary
        )
        fixture.store.toggleFavorite(id: try #require(favoriteID))
        fixture.store.record(
            sourceText: "remove",
            translatedText: "删除",
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            backend: "llm",
            kind: .translation
        )

        fixture.store.clearNonFavorites()

        #expect(fixture.store.entries.count == 1)
        #expect(fixture.store.entries[0].id == favoriteID)
        #expect(fixture.store.entries[0].isFavorite)
    }

    @Test
    func exportingFavoritesWritesOnlyFavoriteEntries() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let favoriteID = fixture.store.record(
            sourceText: "keep",
            translatedText: "保留",
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            backend: "llm",
            kind: .translation
        )
        fixture.store.toggleFavorite(id: try #require(favoriteID))
        fixture.store.record(
            sourceText: "skip",
            translatedText: "跳过",
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            backend: "llm",
            kind: .translation
        )

        let exportURL = fixture.directoryURL.appendingPathComponent("favorites.json")
        let exportedCount = try fixture.store.exportEntries(favoritesOnly: true, to: exportURL)
        let data = try Data(contentsOf: exportURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let exportedEntries = try decoder.decode([TranslationHistoryEntry].self, from: data)

        #expect(exportedCount == 1)
        #expect(exportedEntries.count == 1)
        #expect(exportedEntries[0].id == favoriteID)
        #expect(exportedEntries[0].isFavorite)
    }

    @Test
    func importingMergesNewerEntriesAndPreservesFavorites() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let existingID = fixture.store.record(
            sourceText: "hello",
            translatedText: "你好",
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            backend: "llm",
            kind: .translation,
            at: Date(timeIntervalSince1970: 1_000)
        )
        fixture.store.toggleFavorite(id: try #require(existingID))

        let importedEntries = [
            TranslationHistoryEntry(
                id: UUID(),
                sourceText: "hello",
                translatedText: "您好",
                sourceLanguage: "en",
                targetLanguage: "zh-CN",
                backend: "llm",
                kind: .translation,
                createdAt: Date(timeIntervalSince1970: 2_000),
                isFavorite: false
            ),
            TranslationHistoryEntry(
                id: UUID(),
                sourceText: "new",
                translatedText: "新增",
                sourceLanguage: "en",
                targetLanguage: "zh-CN",
                backend: "llm",
                kind: .dictionary,
                createdAt: Date(timeIntervalSince1970: 3_000),
                isFavorite: false
            ),
        ]
        let importURL = fixture.directoryURL.appendingPathComponent("import.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(importedEntries).write(to: importURL)

        let result = try fixture.store.importEntries(from: importURL)

        #expect(result == TranslationHistoryImportResult(acceptedCount: 2, addedCount: 1, updatedCount: 1))
        #expect(fixture.store.entries.count == 2)
        let updatedEntry = try #require(fixture.store.entry(id: existingID))
        #expect(updatedEntry.translatedText == "您好")
        #expect(updatedEntry.isFavorite)
    }

    @Test
    func importingInvalidFileDoesNotChangeHistory() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.store.record(
            sourceText: "keep",
            translatedText: "保留",
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            backend: "llm",
            kind: .translation
        )
        let previousEntries = fixture.store.entries
        let importURL = fixture.directoryURL.appendingPathComponent("invalid.json")
        try Data("{}".utf8).write(to: importURL)

        do {
            _ = try fixture.store.importEntries(from: importURL)
            Issue.record("Expected an invalid import file to throw")
        } catch {
            #expect(error is TranslationHistoryTransferError)
        }
        #expect(fixture.store.entries == previousEntries)
    }

    private func makeFixture(maxRecentItems: Int = 500) throws -> HistoryStoreFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoTranslatorHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent("history.json")
        return HistoryStoreFixture(
            store: TranslationHistoryStore(fileURL: fileURL, maxRecentItems: maxRecentItems),
            fileURL: fileURL,
            directoryURL: directoryURL
        )
    }
}

@MainActor
private struct HistoryStoreFixture {
    let store: TranslationHistoryStore
    let fileURL: URL
    let directoryURL: URL

    func cleanup() {
        // 历史写入是后台异步的；先同步落盘，避免去抖写入在目录被删后重建临时目录。
        store.flush()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

struct LRUCacheTests {
    @Test
    func capacityEvictsLeastRecentlyUsed() {
        let cache = LRUCache<String, Int>(capacity: 2)
        cache.setValue(1, forKey: "a")
        cache.setValue(2, forKey: "b")
        #expect(cache.value(forKey: "a") == 1) // a 变为最近使用
        cache.setValue(3, forKey: "c")

        #expect(cache.value(forKey: "b") == nil)
        #expect(cache.value(forKey: "a") == 1)
        #expect(cache.value(forKey: "c") == 3)
    }

    @Test
    func totalCostLimitEvictsUntilUnderLimit() {
        let cache = LRUCache<String, Int>(capacity: 10, totalCostLimit: 100)
        cache.setValue(1, forKey: "a", cost: 40)
        cache.setValue(2, forKey: "b", cost: 40)
        cache.setValue(3, forKey: "c", cost: 40) // 总成本 120 > 100，应淘汰最久未用的 a

        #expect(cache.value(forKey: "a") == nil)
        #expect(cache.value(forKey: "b") == 2)
        #expect(cache.value(forKey: "c") == 3)
    }

    @Test
    func totalCostLimitKeepsMostRecentEntryEvenIfOversized() {
        let cache = LRUCache<String, Int>(capacity: 10, totalCostLimit: 50)
        cache.setValue(1, forKey: "a", cost: 10)
        cache.setValue(2, forKey: "huge", cost: 999) // 超限也至少保留最近一条

        #expect(cache.value(forKey: "a") == nil)
        #expect(cache.value(forKey: "huge") == 2)
    }

    @Test
    func updatingExistingKeyReplacesCost() {
        let cache = LRUCache<String, Int>(capacity: 10, totalCostLimit: 100)
        cache.setValue(1, forKey: "a", cost: 90)
        cache.setValue(2, forKey: "a", cost: 10) // 旧成本应被替换而非累加
        cache.setValue(3, forKey: "b", cost: 80)

        #expect(cache.value(forKey: "a") == 2)
        #expect(cache.value(forKey: "b") == 3)
    }
}
