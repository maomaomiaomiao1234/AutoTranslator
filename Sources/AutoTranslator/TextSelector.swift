import Cocoa
import ApplicationServices
import CoreGraphics

final class TextSelector {
    private struct PasteboardItemSnapshot {
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    private struct PasteboardSnapshot {
        let items: [PasteboardItemSnapshot]
        let fallbackString: String?
        let hadContents: Bool
    }

    private let copyInterval: TimeInterval
    private let copyPollIntervalNs: UInt64
    private let maxCopyPollCount: Int
    private var lastCopyTime: TimeInterval = 0

    init(copyInterval: TimeInterval = 0.4,
         copyPollInterval: TimeInterval = 0.01,
         maxCopyPollCount: Int = 20) {
        self.copyInterval = copyInterval
        self.copyPollIntervalNs = UInt64(copyPollInterval * 1_000_000_000)
        self.maxCopyPollCount = maxCopyPollCount
    }

    @MainActor
    func getSelectedText(allowClipboardFallback: Bool = false,
                         previousText: String = "") async -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier

        // 尝试 Accessibility API
        if let text = getSelectedTextViaAccessibility(pid: pid) {
            return text
        }

        guard allowClipboardFallback else { return nil }
        return await getByClipboard(previousText: previousText)
    }

    private func getSelectedTextViaAccessibility(pid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focused = focused else { return nil }

        var selected: CFTypeRef?
        let selErr = AXUIElementCopyAttributeValue(
            focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected
        )
        guard selErr == .success, let text = selected as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    private func getByClipboard(previousText: String) async -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCopyTime < copyInterval { return nil }
        lastCopyTime = now

        let pb = NSPasteboard.general
        let snapshot = capturePasteboardSnapshot(pb)
        let oldCount = pb.changeCount
        defer { restorePasteboardSnapshot(snapshot, to: pb) }

        simulateCmdC()

        var newText: String? = nil
        for _ in 0..<maxCopyPollCount {
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: copyPollIntervalNs)
            if pb.changeCount != oldCount {
                newText = pb.string(forType: .string)
                break
            }
        }

        guard let text = newText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text != previousText else { return nil }
        return text
    }

    @MainActor
    private func capturePasteboardSnapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems ?? []
        let snapshots = items.map { item in
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType[type] = data
                }
            }
            return PasteboardItemSnapshot(dataByType: dataByType)
        }
        return PasteboardSnapshot(
            items: snapshots,
            fallbackString: pasteboard.string(forType: .string),
            hadContents: !items.isEmpty
        )
    }

    @MainActor
    private func restorePasteboardSnapshot(_ snapshot: PasteboardSnapshot, to pb: NSPasteboard) {
        pb.clearContents()
        guard snapshot.hadContents else { return }

        let restoredItems = snapshot.items.compactMap { snapshot -> NSPasteboardItem? in
            guard !snapshot.dataByType.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in snapshot.dataByType {
                item.setData(data, forType: type)
            }
            return item
        }

        if !restoredItems.isEmpty {
            pb.writeObjects(restoredItems)
            return
        }

        guard let fallbackString = snapshot.fallbackString else { return }
        pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType")], owner: nil)
        pb.setString(fallbackString, forType: .string)
    }

    private func simulateCmdC() {
        let src = CGEventSource(stateID: .hidSystemState)

        let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
        up?.post(tap: .cghidEventTap)
    }
}
