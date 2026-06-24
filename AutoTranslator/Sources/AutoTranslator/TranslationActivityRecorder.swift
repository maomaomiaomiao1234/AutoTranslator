import Foundation

#if os(macOS)
import AppKit
#endif

struct TranslationActivityEvent: Codable, Hashable, Sendable {
    let id: UUID
    let occurredAt: Date
    let kind: Kind

    enum Kind: String, Codable, Sendable {
        case selectionTranslation
    }
}

enum TranslationActivityRecorder {
    static let appGroupIdentifier = "group.com.whang1234.device-moments"

    #if os(macOS)
    static let selectionTranslationNotification = Notification.Name("com.whang1234.AutoTranslator.selectionTranslationRecorded")
    #endif

    static func recordSelectionTranslation(id: UUID, occurredAt: Date) {
        guard let storageURL = storageURL() else {
            AppLog.error("无法写入划词统计：共享 App Group 不可用")
            return
        }

        do {
            var events = try readEvents(from: storageURL)
            guard !events.contains(where: { $0.id == id }) else { return }

            events.append(TranslationActivityEvent(
                id: id,
                occurredAt: occurredAt,
                kind: .selectionTranslation
            ))
            events.sort { $0.occurredAt > $1.occurredAt }
            if events.count > 10_000 {
                events = Array(events.prefix(10_000))
            }

            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder.translationActivity.encode(events).write(to: storageURL, options: .atomic)

            #if os(macOS)
            DistributedNotificationCenter.default().postNotificationName(
                selectionTranslationNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            #endif
        } catch {
            AppLog.error("无法写入划词统计：\(error.localizedDescription)")
        }
    }

    private static func storageURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appending(path: "translation-activity.json", directoryHint: .notDirectory)
    }

    private static func readEvents(from storageURL: URL) throws -> [TranslationActivityEvent] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return [] }
        return try JSONDecoder.translationActivity.decode(
            [TranslationActivityEvent].self,
            from: Data(contentsOf: storageURL)
        )
    }
}

private extension JSONEncoder {
    static var translationActivity: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}

private extension JSONDecoder {
    static var translationActivity: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
