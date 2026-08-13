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

struct LLMTranslatorEndpointTests {
    @Test
    func recognizesOpenRouterBaseURLs() {
        #expect(LLMTranslator.isOpenRouterBaseURL("https://openrouter.ai/api/v1"))
        #expect(LLMTranslator.isOpenRouterBaseURL("https://OPENROUTER.AI/api/v1/"))
        #expect(LLMTranslator.isOpenRouterBaseURL("https://api.openrouter.ai/v1"))
    }

    @Test
    func rejectsLookalikeOpenRouterHosts() {
        #expect(!LLMTranslator.isOpenRouterBaseURL("https://openrouter.ai.example.com/api/v1"))
        #expect(!LLMTranslator.isOpenRouterBaseURL("https://notopenrouter.ai/api/v1"))
        #expect(!LLMTranslator.isOpenRouterBaseURL("not a URL"))
    }

    @Test
    func recognizesOfficialDeepSeekBaseURLs() {
        #expect(LLMTranslator.isOfficialDeepSeekBaseURL("https://api.deepseek.com"))
        #expect(LLMTranslator.isOfficialDeepSeekBaseURL("https://API.DEEPSEEK.COM/v1/"))
    }

    @Test
    func rejectsLookalikeDeepSeekHosts() {
        #expect(!LLMTranslator.isOfficialDeepSeekBaseURL("https://api.deepseek.com.example.com"))
        #expect(!LLMTranslator.isOfficialDeepSeekBaseURL("https://deepseek.com"))
        #expect(!LLMTranslator.isOfficialDeepSeekBaseURL("not a URL"))
    }
}

struct LLMStreamParserTests {
    private func chunk(token: String? = nil, finishReason: String? = nil) -> String {
        var choice: [String: Any] = ["delta": token.map { ["content": $0] } ?? [:]]
        choice["finish_reason"] = finishReason ?? NSNull()
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
        return "data: " + String(data: data, encoding: .utf8)!
    }

    @Test
    func normalStreamYieldsTokensAndValidates() throws {
        var parser = LLMStreamParser()
        #expect(try parser.consume(line: chunk(token: "你")) == "你")
        #expect(try parser.consume(line: chunk(token: "好")) == "好")
        #expect(try parser.consume(line: chunk(finishReason: "stop")) == nil)
        #expect(try parser.consume(line: "data: [DONE]") == nil)
        try parser.validateCompletion()
    }

    @Test
    func doneMarkerAloneIsNotProofOfCompleteness() throws {
        var parser = LLMStreamParser()
        _ = try parser.consume(line: chunk(token: "半截"))
        _ = try parser.consume(line: "data: [DONE]")
        #expect(throws: (any Error).self) { try parser.validateCompletion() }
    }

    @Test
    func lengthTruncationFailsEvenWithDoneMarker() throws {
        var parser = LLMStreamParser()
        _ = try parser.consume(line: chunk(token: "被截断的"))
        _ = try parser.consume(line: chunk(finishReason: "length"))
        _ = try parser.consume(line: "data: [DONE]")
        #expect(throws: (any Error).self) { try parser.validateCompletion() }
    }

    @Test
    func interruptedStreamWithoutCompletionFails() throws {
        var parser = LLMStreamParser()
        _ = try parser.consume(line: chunk(token: "网络中断前的内容"))
        #expect(throws: (any Error).self) { try parser.validateCompletion() }
    }

    @Test
    func emptyStreamWithoutTokensPassesValidation() throws {
        let parser = LLMStreamParser()
        try parser.validateCompletion()
    }

    @Test
    func inlineErrorObjectThrowsInsteadOfBeingSwallowed() throws {
        var parser = LLMStreamParser()
        let line = #"data: {"error": {"message": "insufficient quota", "code": 402}}"#
        #expect(throws: (any Error).self) { _ = try parser.consume(line: line) }
    }

    @Test
    func toleratesDataPrefixWithoutSpaceAndSkipsMalformedChunks() throws {
        var parser = LLMStreamParser()
        let noSpace = #"data:{"choices":[{"delta":{"content":"紧凑"}}]}"#
        #expect(try parser.consume(line: noSpace) == "紧凑")
        #expect(try parser.consume(line: "data: {malformed json") == nil)
        #expect(try parser.consume(line: ": keep-alive comment") == nil)
        #expect(try parser.consume(line: "") == nil)
        _ = try parser.consume(line: chunk(finishReason: "stop"))
        try parser.validateCompletion()
    }
}

struct SelectionAccessibilityStrategyTests {
    @Test
    func explicitSelectionUsesFastLocalAXWhenClipboardFallbackIsAvailable() {
        let strategy = SelectionAccessibilityStrategy.resolve(
            allowClipboardFallback: true,
            allowDeepAccessibilitySearch: true
        )

        #expect(strategy == .fastLocal)
    }

    @Test
    func clipboardOptOutPreservesFullAXSearch() {
        let strategy = SelectionAccessibilityStrategy.resolve(
            allowClipboardFallback: false,
            allowDeepAccessibilitySearch: true
        )

        #expect(strategy == .full)
    }

    @Test
    func inconclusiveClickKeepsLightweightProbe() {
        let strategy = SelectionAccessibilityStrategy.resolve(
            allowClipboardFallback: false,
            allowDeepAccessibilitySearch: false
        )

        #expect(strategy == .lightweight)
    }
}

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
    func paginationKeepsOnlyOneBoundedPageInMemory() throws {
        let fixture = try makeFixture(maxRecentItems: 20, pageSize: 2)
        defer { fixture.cleanup() }

        var ids: [UUID] = []
        for index in 0..<5 {
            let id = fixture.store.record(
                sourceText: "source-\(index)",
                translatedText: "translation-\(index)",
                sourceLanguage: "en",
                targetLanguage: "zh-CN",
                backend: "llm",
                kind: .translation,
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
            ids.append(try #require(id))
        }

        #expect(fixture.store.totalEntryCount == 5)
        #expect(fixture.store.filteredEntryCount == 5)
        #expect(fixture.store.entries.count == 2)
        #expect(fixture.store.pageCount == 3)
        let firstPageIDs = Set(fixture.store.entries.map(\.id))

        fixture.store.goToNextPage()
        #expect(fixture.store.currentPage == 1)
        #expect(fixture.store.entries.count == 2)
        #expect(firstPageIDs.isDisjoint(with: Set(fixture.store.entries.map(\.id))))

        fixture.store.goToNextPage()
        #expect(fixture.store.currentPage == 2)
        #expect(fixture.store.entries.count == 1)
        #expect(!fixture.store.canGoToNextPage)

        for id in ids {
            fixture.store.toggleFavorite(id: id)
        }
        fixture.store.updateQuery(searchText: "", favoritesOnly: true)
        #expect(fixture.store.favoriteEntryCount == 5)
        #expect(fixture.store.filteredEntryCount == 5)
        #expect(fixture.store.entries.count == 2)
        #expect(fixture.store.pageCount == 3)

        fixture.store.updateQuery(searchText: "英语", favoritesOnly: false)
        #expect(fixture.store.filteredEntryCount == 5)
        #expect(fixture.store.entries.count == 2)
        fixture.store.updateQuery(searchText: "source-3", favoritesOnly: false)
        #expect(fixture.store.filteredEntryCount == 1)
        #expect(fixture.store.entries.first?.sourceText == "source-3")

        fixture.store.updateQuery(searchText: "", favoritesOnly: false)
        fixture.store.deactivatePageLoading()
        #expect(fixture.store.entries.isEmpty)
        #expect(fixture.store.totalEntryCount == 5)
        #expect(fixture.store.entry(id: ids[0]) != nil)
        fixture.store.record(
            sourceText: "source-5",
            translatedText: "translation-5",
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            backend: "llm",
            kind: .translation
        )
        #expect(fixture.store.totalEntryCount == 6)
        #expect(fixture.store.entries.isEmpty)
        fixture.store.activatePageLoading()
        #expect(fixture.store.entries.count == 2)
    }

    @Test
    func legacyJSONMigratesOnceAndIsPreservedAsBackup() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoTranslatorHistoryMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let legacyURL = directoryURL.appendingPathComponent("history.json")
        let entries = (0..<3).map { index in
            TranslationHistoryEntry(
                id: UUID(),
                sourceText: "legacy-\(index)",
                translatedText: "旧记录-\(index)",
                sourceLanguage: "en",
                targetLanguage: "zh-CN",
                backend: "google",
                kind: .translation,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                isFavorite: index == 0
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(entries).write(to: legacyURL)

        let store = TranslationHistoryStore(fileURL: legacyURL, pageSize: 2)
        #expect(store.totalEntryCount == 3)
        #expect(store.favoriteEntryCount == 1)
        #expect(store.entries.count == 2)
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(FileManager.default.fileExists(
            atPath: legacyURL.appendingPathExtension("migrated-backup").path
        ))

        store.flush()
        let reloaded = TranslationHistoryStore(fileURL: legacyURL, pageSize: 2)
        #expect(reloaded.totalEntryCount == 3)
        #expect(reloaded.entries.count == 2)
        #expect(entries.allSatisfy { reloaded.entry(id: $0.id) != nil })
    }

    @Test
    func diskDatabaseFailureFallsBackToMemoryWithoutConsumingLegacyJSON() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoTranslatorHistoryFallbackTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let legacyURL = directoryURL.appendingPathComponent("history.json")
        let legacyEntry = TranslationHistoryEntry(
            id: UUID(),
            sourceText: "legacy",
            translatedText: "旧记录",
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            backend: "google",
            kind: .translation,
            createdAt: Date(timeIntervalSince1970: 1_000),
            isFavorite: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode([legacyEntry]).write(to: legacyURL)

        // 用同名目录占住 history.sqlite3 路径，迫使磁盘库打开失败。
        let databaseURL = directoryURL.appendingPathComponent("history.sqlite3")
        try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)

        let fallbackStore = TranslationHistoryStore(fileURL: legacyURL)
        #expect(!fallbackStore.isPersistent)
        // 回退会话不迁移：旧 JSON 原样保留、不得改名，否则磁盘库恢复后旧历史静默丢失。
        #expect(FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: legacyURL.appendingPathExtension("migrated-backup").path
        ))
        #expect(fallbackStore.totalEntryCount == 0)

        // 内存库在本会话内仍可正常读写。
        let sessionID = fallbackStore.record(
            sourceText: "session",
            translatedText: "本会话",
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            backend: "google",
            kind: .translation
        )
        #expect(sessionID != nil)
        #expect(fallbackStore.totalEntryCount == 1)

        // 磁盘障碍消除后，下一次启动照常完成迁移，旧历史完整无缺。
        try FileManager.default.removeItem(at: databaseURL)
        let recoveredStore = TranslationHistoryStore(fileURL: legacyURL)
        #expect(recoveredStore.isPersistent)
        #expect(recoveredStore.totalEntryCount == 1)
        #expect(recoveredStore.entry(id: legacyEntry.id)?.isFavorite == true)
        #expect(FileManager.default.fileExists(
            atPath: legacyURL.appendingPathExtension("migrated-backup").path
        ))
    }

    @Test
    func exportReadsAllDatabaseRowsInsteadOfOnlyCurrentPage() throws {
        let fixture = try makeFixture(maxRecentItems: 20, pageSize: 2)
        defer { fixture.cleanup() }

        for index in 0..<5 {
            fixture.store.record(
                sourceText: "export-\(index)",
                translatedText: "导出-\(index)",
                sourceLanguage: "en",
                targetLanguage: "zh-CN",
                backend: "google",
                kind: .translation
            )
        }
        #expect(fixture.store.entries.count == 2)

        let exportURL = fixture.directoryURL.appendingPathComponent("all.json")
        let count = try fixture.store.exportEntries(favoritesOnly: false, to: exportURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let exported = try decoder.decode(
            [TranslationHistoryEntry].self,
            from: Data(contentsOf: exportURL)
        )
        #expect(count == 5)
        #expect(exported.count == 5)
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

    @Test
    func exportingMarkdownWritesOnlyFavoritesAsReadableDocument() throws {
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

        let exportURL = fixture.directoryURL.appendingPathComponent("favorites.md")
        let exportedCount = try fixture.store.exportEntries(favoritesOnly: true, format: .markdown, to: exportURL)
        let text = try String(contentsOf: exportURL, encoding: .utf8)

        #expect(exportedCount == 1)
        #expect(text.contains("# AutoTranslator 翻译历史"))
        #expect(text.contains("> keep"))
        #expect(text.contains("> 保留"))
        #expect(!text.contains("skip"))
    }

    @Test
    func exportingPDFWritesValidPDFData() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        fixture.store.record(
            sourceText: "hello",
            translatedText: "你好",
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            backend: "llm",
            kind: .translation
        )

        let exportURL = fixture.directoryURL.appendingPathComponent("history.pdf")
        let exportedCount = try fixture.store.exportEntries(favoritesOnly: false, format: .pdf, to: exportURL)
        let data = try Data(contentsOf: exportURL)

        #expect(exportedCount == 1)
        #expect(!data.isEmpty)
        #expect(data.starts(with: Array("%PDF".utf8)))
    }

    private func makeFixture(maxRecentItems: Int = 500, pageSize: Int = 100) throws -> HistoryStoreFixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoTranslatorHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL.appendingPathComponent("history.json")
        return HistoryStoreFixture(
            store: TranslationHistoryStore(
                fileURL: fileURL,
                maxRecentItems: maxRecentItems,
                pageSize: pageSize
            ),
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

@MainActor
struct HistoryExportRendererTests {
    private func makeEntry(
        source: String = "hello",
        translated: String = "你好",
        kind: TranslationHistoryKind = .translation,
        favorite: Bool = false
    ) -> TranslationHistoryEntry {
        TranslationHistoryEntry(
            id: UUID(),
            sourceText: source,
            translatedText: translated,
            sourceLanguage: "en",
            targetLanguage: "zh-CN",
            backend: "llm",
            kind: kind,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000),
            isFavorite: favorite
        )
    }

    @Test
    func markdownEscapesStructuralCharactersAndUsesDictionaryWording() {
        let entry = makeEntry(
            source: "**bold** [link](x) `code`",
            translated: "第一行\n第二行",
            kind: .dictionary
        )
        let markdown = HistoryExportRenderer.markdown(for: [entry])

        #expect(markdown.contains("共 1 条记录"))
        #expect(markdown.contains("**释义**")) // 词典条目的译文块标题
        #expect(markdown.contains(#"> \*\*bold\*\* \[link\](x) \`code\`"#))
        #expect(markdown.contains("> 第一行\n> 第二行")) // 多行文本逐行加引用前缀
    }

    @Test
    func htmlEscapesMarkupAndMarksFavorites() {
        let entry = makeEntry(
            source: "<script>alert('x & y')</script>",
            translated: "安全",
            favorite: true
        )
        let html = HistoryExportRenderer.html(for: [entry])

        #expect(html.contains("<meta charset=\"utf-8\">"))
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;alert(&#39;x &amp; y&#39;)&lt;/script&gt;"))
        #expect(html.contains("安全"))
        #expect(html.contains("译文"))
        #expect(html.contains("⭐️ 收藏"))
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

/// 全部使用唯一命名的私有 pasteboard，绝不触碰 NSPasteboard.general。
@MainActor
struct TextSelectorPasteboardTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("AutoTranslatorTests.\(UUID().uuidString)"))
    }

    @Test
    func restorePutsOriginalDataOnFirstItemWithTransientMarker() throws {
        let selector = TextSelector()
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("原始内容", forType: .string)

        let snapshot = try #require(selector.capturePasteboardSnapshot(pb))
        pb.clearContents()
        pb.setString("划词临时内容", forType: .string)
        selector.restorePasteboardSnapshot(snapshot, to: pb)

        // 回归：旧实现 declareTypes+writeObjects 会产生声明 .string 却无数据的 item 0，
        // 按「第一个含该类型的 item」读取的程序会拿到空剪贴板。
        let firstItem = try #require(pb.pasteboardItems?.first)
        #expect(firstItem.string(forType: .string) == "原始内容")
        #expect(firstItem.types.map(\.rawValue).contains("org.nspasteboard.TransientType"))
        #expect(pb.string(forType: .string) == "原始内容")
    }

    @Test
    func restorePreservesMultipleItemsInOrder() throws {
        let selector = TextSelector()
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let first = NSPasteboardItem()
        first.setString("第一项", forType: .string)
        let second = NSPasteboardItem()
        second.setString("第二项", forType: .string)
        pb.writeObjects([first, second])

        let snapshot = try #require(selector.capturePasteboardSnapshot(pb))
        pb.clearContents()
        selector.restorePasteboardSnapshot(snapshot, to: pb)

        let strings = (pb.pasteboardItems ?? []).map { $0.string(forType: .string) }
        #expect(strings == ["第一项", "第二项"])
    }

    @Test
    func emptySnapshotRestoreLeavesPasteboardUntouched() {
        let selector = TextSelector()
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("不能被清掉", forType: .string)
        let countBefore = pb.changeCount

        // Deny 场景防线：读取被拒时快照为空，恢复决不能清空用户剪贴板。
        let emptySnapshot = TextSelector.PasteboardSnapshot(
            items: [],
            fallbackString: nil,
            hadContents: false
        )
        selector.restorePasteboardSnapshot(emptySnapshot, to: pb)

        #expect(pb.changeCount == countBefore)
        #expect(pb.string(forType: .string) == "不能被清掉")
    }

    @Test
    func oversizedPasteboardAbortsSnapshot() {
        let selector = TextSelector(maxSnapshotBytes: 8)
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("0123456789ABCDEF", forType: .string) // 16 字节 > 8 字节预算

        #expect(selector.capturePasteboardSnapshot(pb) == nil)
    }

    @Test
    func concealedAndPromiseTypesBlockClipboardFallback() {
        let concealed = makePasteboard()
        defer { concealed.releaseGlobally() }
        concealed.clearContents()
        let secretItem = NSPasteboardItem()
        secretItem.setString("secret", forType: .string)
        secretItem.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        concealed.writeObjects([secretItem])
        #expect(TextSelector.pasteboardHoldsUnrestorableContent(concealed))

        let promise = makePasteboard()
        defer { promise.releaseGlobally() }
        promise.clearContents()
        let promiseItem = NSPasteboardItem()
        promiseItem.setData(Data(), forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"))
        promise.writeObjects([promiseItem])
        #expect(TextSelector.pasteboardHoldsUnrestorableContent(promise))

        let plain = makePasteboard()
        defer { plain.releaseGlobally() }
        plain.clearContents()
        plain.setString("普通文本", forType: .string)
        #expect(!TextSelector.pasteboardHoldsUnrestorableContent(plain))
    }
}
