import Cocoa
import ApplicationServices
import CoreGraphics

final class TextSelector {
    private static let axChildAttributeNames: [CFString] = [
        "AXChildren" as CFString,
        "AXVisibleChildren" as CFString,
        "AXContents" as CFString,
        "AXRows" as CFString,
        "AXVisibleRows" as CFString,
        "AXColumns" as CFString,
        "AXVisibleColumns" as CFString,
        "AXCells" as CFString,
        "AXVisibleCells" as CFString,
    ]

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
    private let maxAXDescendantSearchCount: Int
    private var lastCopyTime: TimeInterval = 0

    init(copyInterval: TimeInterval = 0.12,
         copyPollInterval: TimeInterval = 0.01,
         maxCopyPollCount: Int = 20,
         maxAXDescendantSearchCount: Int = 180) {
        self.copyInterval = copyInterval
        self.copyPollIntervalNs = UInt64(copyPollInterval * 1_000_000_000)
        self.maxCopyPollCount = maxCopyPollCount
        self.maxAXDescendantSearchCount = maxAXDescendantSearchCount
    }

    @MainActor
    func getSelectedText(allowClipboardFallback: Bool = false,
                         allowDeepAccessibilitySearch: Bool = true) async -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            AppLog.debug("TextSelector failed: no frontmost application")
            return nil
        }
        let pid = frontApp.processIdentifier
        let bundleID = frontApp.bundleIdentifier ?? "<unknown>"
        AppLog.debug("TextSelector begin app=\(bundleID) pid=\(pid) allowClipboardFallback=\(allowClipboardFallback) allowDeepAX=\(allowDeepAccessibilitySearch)")

        // 尝试 Accessibility API
        if let text = getSelectedTextViaAccessibility(
            pid: pid,
            allowDeepAccessibilitySearch: allowDeepAccessibilitySearch
        ) {
            AppLog.debug("TextSelector success via AX length=\(text.count) app=\(bundleID)")
            return text
        }

        guard allowClipboardFallback else {
            AppLog.debug("TextSelector failed: AX unavailable and clipboard fallback disabled app=\(bundleID)")
            return nil
        }
        let text = await getByClipboard()
        if let text {
            AppLog.debug("TextSelector success via clipboard length=\(text.count) app=\(bundleID)")
        } else {
            AppLog.debug("TextSelector failed: clipboard fallback returned nil app=\(bundleID)")
        }
        return text
    }

    private func getSelectedTextViaAccessibility(pid: pid_t,
                                                 allowDeepAccessibilitySearch: Bool) -> String? {
        let appRef = AXUIElementCreateApplication(pid)
        let focusedResult = copyAXElementAttribute(appRef, kAXFocusedUIElementAttribute as CFString)
        guard let focused = focusedResult.element else {
            AppLog.debug("TextSelector AX focused element unavailable err=\(focusedResult.error.rawValue)")
            return getSelectedTextViaAccessibilityWindowSearch(
                appRef: appRef,
                allowDeepAccessibilitySearch: allowDeepAccessibilitySearch
            )
        }

        if let text = selectedText(from: focused) {
            return text
        }
        AppLog.debug("TextSelector AX focused selected text unavailable")

        guard allowDeepAccessibilitySearch else {
            AppLog.debug("TextSelector AX descendant search skipped for lightweight probe")
            return getSelectedTextViaAccessibilityWindowSearch(
                appRef: appRef,
                allowDeepAccessibilitySearch: false
            )
        }

        if let text = findSelectedTextInAXDescendants(
            startingAt: [focused],
            context: "focusedElement"
        ) {
            return text
        }

        return getSelectedTextViaAccessibilityWindowSearch(
            appRef: appRef,
            allowDeepAccessibilitySearch: true
        )
    }

    private func getSelectedTextViaAccessibilityWindowSearch(appRef: AXUIElement,
                                                            allowDeepAccessibilitySearch: Bool) -> String? {
        let windowResult = copyAXElementAttribute(appRef, kAXFocusedWindowAttribute as CFString)
        if let focusedWindow = windowResult.element {
            if let text = selectedText(from: focusedWindow) {
                return text
            }
            guard allowDeepAccessibilitySearch else {
                AppLog.debug("TextSelector AX focused window descendant search skipped for lightweight probe")
                return nil
            }
            if let text = findSelectedTextInAXDescendants(
                startingAt: [focusedWindow],
                context: "focusedWindow"
            ) {
                return text
            }
        } else {
            AppLog.debug("TextSelector AX focused window unavailable err=\(windowResult.error.rawValue)")
        }

        guard allowDeepAccessibilitySearch else { return nil }

        let windows = copyAXChildElements(from: appRef, attribute: kAXWindowsAttribute as CFString)
        guard !windows.isEmpty else {
            AppLog.debug("TextSelector AX windows unavailable")
            return nil
        }

        return findSelectedTextInAXDescendants(
            startingAt: windows,
            context: "windows"
        )
    }

    private func selectedText(from element: AXUIElement) -> String? {
        var selected: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selected
        )
        guard error == .success, let selected else {
            return nil
        }

        let text: String?
        if let string = selected as? String {
            text = string
        } else if let attributedString = selected as? NSAttributedString {
            text = attributedString.string
        } else {
            text = nil
        }

        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func findSelectedTextInAXDescendants(startingAt roots: [AXUIElement],
                                                context: String) -> String? {
        var queue = roots
        var index = 0
        var inspectedCount = 0
        var visited = Set<CFHashCode>()

        while index < queue.count, inspectedCount < maxAXDescendantSearchCount {
            let element = queue[index]
            index += 1

            let identity = CFHash(element)
            guard visited.insert(identity).inserted else { continue }

            inspectedCount += 1
            if let text = selectedText(from: element) {
                AppLog.debug(
                    "TextSelector AX selected text found context=\(context) inspected=\(inspectedCount) length=\(text.count)"
                )
                return text
            }

            for attribute in Self.axChildAttributeNames {
                queue.append(contentsOf: copyAXChildElements(from: element, attribute: attribute))
            }
        }

        AppLog.debug(
            "TextSelector AX descendant search exhausted context=\(context) inspected=\(inspectedCount)"
        )
        return nil
    }

    private func copyAXElementAttribute(_ element: AXUIElement,
                                        _ attribute: CFString) -> (error: AXError, element: AXUIElement?) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success, let value else {
            return (error, nil)
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (error, nil)
        }
        return (error, (value as! AXUIElement))
    }

    private func copyAXChildElements(from element: AXUIElement,
                                     attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success, let value else {
            return []
        }
        if let array = value as? [AXUIElement] {
            return array
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return []
        }
        return [value as! AXUIElement]
    }

    @MainActor
    private func getByClipboard() async -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - lastCopyTime
        if elapsed < copyInterval {
            AppLog.debug("TextSelector clipboard skipped: rate limited elapsed=\(Self.seconds(elapsed))s")
            return nil
        }
        lastCopyTime = now

        let pb = NSPasteboard.general
        let snapshot = capturePasteboardSnapshot(pb)
        let oldCount = pb.changeCount
        defer { restorePasteboardSnapshot(snapshot, to: pb) }

        AppLog.debug("TextSelector clipboard copy requested oldChangeCount=\(oldCount) hadContents=\(snapshot.hadContents)")
        simulateCmdC()

        var newText: String? = nil
        var pollIndex = 0
        for index in 0..<maxCopyPollCount {
            pollIndex = index + 1
            if Task.isCancelled {
                AppLog.debug("TextSelector clipboard cancelled while polling")
                return nil
            }
            try? await Task.sleep(nanoseconds: copyPollIntervalNs)
            if pb.changeCount != oldCount {
                newText = pb.string(forType: .string)
                AppLog.debug("TextSelector clipboard changed after polls=\(pollIndex) newChangeCount=\(pb.changeCount)")
                break
            }
        }

        guard let text = newText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            AppLog.debug("TextSelector clipboard failed: no text after polls=\(pollIndex)")
            return nil
        }
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
            pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType")], owner: nil)
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

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }
}
