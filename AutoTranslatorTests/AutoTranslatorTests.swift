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
