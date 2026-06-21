//
//  AutoTranslatorTests.swift
//  AutoTranslatorTests
//
//  Created by hang w on 12/6/26.
//

import Foundation
import Testing
@testable import AutoTranslator

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
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
