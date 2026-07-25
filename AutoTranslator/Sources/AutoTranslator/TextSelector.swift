import Cocoa
import ApplicationServices
import CoreGraphics

nonisolated enum SelectionAccessibilityStrategy: Equatable, Sendable {
    case lightweight
    case fastLocal
    case full

    static func resolve(allowClipboardFallback: Bool,
                        allowDeepAccessibilitySearch: Bool) -> Self {
        guard allowDeepAccessibilitySearch else { return .lightweight }
        return allowClipboardFallback ? .fastLocal : .full
    }
}

private actor AccessibilityLookupGate {
    func perform(_ operation: @Sendable () -> String?) -> String? {
        operation()
    }
}

final class TextSelector {
    nonisolated private static let axChildAttributeNames: [CFString] = [
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
    nonisolated private static let axLocalChildAttributeNames: [CFString] = [
        kAXChildrenAttribute as CFString,
        "AXVisibleChildren" as CFString,
        "AXContents" as CFString,
    ]
    nonisolated private static let fastAccessibilityBudget: TimeInterval = 0.18
    nonisolated private static let maxLocalAXSearchCount = 24
    nonisolated private static let maxLocalAXAncestorCount = 8

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
    private let accessibilityLookupGate = AccessibilityLookupGate()
    private var lastCopyTime: TimeInterval = 0

    init(copyInterval: TimeInterval = 0.12,
         copyPollInterval: TimeInterval = 0.01,
         maxCopyPollCount: Int = 20,
         maxAXDescendantSearchCount: Int = 180) {
        self.copyInterval = copyInterval
        self.copyPollIntervalNs = UInt64(copyPollInterval * 1_000_000_000)
        self.maxCopyPollCount = maxCopyPollCount
        self.maxAXDescendantSearchCount = maxAXDescendantSearchCount
        // 对 app 元素设置的超时只作用于对该元素本身的消息；深度搜索访问的子元素
        // 仍走系统默认超时（可达数秒）。对 system-wide 元素设置可令本进程发出的
        // 所有 AX 消息统一使用短超时，覆盖全部取词路径。
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.2)
    }

    @MainActor
    func getSelectedText(allowClipboardFallback: Bool = false,
                         allowDeepAccessibilitySearch: Bool = true,
                         selectionPoint: CGPoint? = nil) async -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            AppLog.debug("TextSelector failed: no frontmost application")
            return nil
        }
        let pid = frontApp.processIdentifier
        let bundleID = frontApp.bundleIdentifier ?? "<unknown>"
        AppLog.debug("TextSelector begin app=\(bundleID) pid=\(pid) allowClipboardFallback=\(allowClipboardFallback) allowDeepAX=\(allowDeepAccessibilitySearch)")

        let strategy = SelectionAccessibilityStrategy.resolve(
            allowClipboardFallback: allowClipboardFallback,
            allowDeepAccessibilitySearch: allowDeepAccessibilitySearch
        )

        // AX 为同步跨进程调用，放到独立 actor 串行执行：新一轮取词取消旧 Task 后，
        // 旧查询会在当前 AX 调用返回时观察到取消并停止，不会因连续划词堆积多个深搜。
        let maxDescendantSearchCount = maxAXDescendantSearchCount
        let axText = await accessibilityLookupGate.perform {
            Self.getSelectedTextViaAccessibility(
                pid: pid,
                selectionPoint: selectionPoint,
                strategy: strategy,
                maxDescendantSearchCount: maxDescendantSearchCount
            )
        }
        if Task.isCancelled {
            AppLog.debug("TextSelector cancelled during AX lookup app=\(bundleID)")
            return nil
        }
        if let text = axText {
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

    nonisolated private static func getSelectedTextViaAccessibility(
        pid: pid_t,
        selectionPoint: CGPoint?,
        strategy: SelectionAccessibilityStrategy,
        maxDescendantSearchCount: Int
    ) -> String? {
        let appRef = AXUIElementCreateApplication(pid)
        // 目标应用无响应时，AX 调用默认可阻塞主线程达数秒；深度搜索会遍历上百个元素，
        // 极端情况下会连锁冻结取词流程。设置消息超时兜底，令单次跨进程查询快速失败。
        AXUIElementSetMessagingTimeout(appRef, 0.2)
        let deadline: TimeInterval? = strategy == .fastLocal
            ? ProcessInfo.processInfo.systemUptime + fastAccessibilityBudget
            : nil

        let focusedResult = copyAXElementAttribute(appRef, kAXFocusedUIElementAttribute as CFString)
        let focused = focusedResult.element
        if focused == nil {
            AppLog.debug("TextSelector AX focused element unavailable err=\(focusedResult.error.rawValue)")
        }

        if let focused, let text = selectedText(from: focused) {
            return text
        }
        AppLog.debug("TextSelector AX focused selected text unavailable")

        guard shouldContinue(until: deadline) else {
            AppLog.debug("TextSelector AX lookup stopped before local search reason=\(stopReason(deadline: deadline))")
            return nil
        }

        if strategy != .lightweight,
           let selectionPoint,
           let text = selectedTextNearPoint(
               selectionPoint,
               appRef: appRef,
               deadline: deadline
           ) {
            return text
        }

        guard shouldContinue(until: deadline) else {
            AppLog.debug("TextSelector AX lookup stopped after local search reason=\(stopReason(deadline: deadline))")
            return nil
        }

        if strategy == .lightweight {
            AppLog.debug("TextSelector AX descendant search skipped for lightweight probe")
            return selectedTextFromFocusedWindow(appRef: appRef)
        }

        if strategy == .fastLocal {
            if let focused,
               let text = findSelectedTextInAXDescendants(
                   startingAt: [focused],
                   context: "focusedElementLocal",
                   maximumCount: maxLocalAXSearchCount,
                   childAttributes: axLocalChildAttributeNames,
                   deadline: deadline
               ) {
                return text
            }

            guard shouldContinue(until: deadline) else {
                AppLog.debug("TextSelector AX fast lookup stopped reason=\(stopReason(deadline: deadline))")
                return nil
            }

            if let text = selectedTextFromFocusedWindow(appRef: appRef) {
                return text
            }
            AppLog.debug("TextSelector AX fast local lookup exhausted; using clipboard fallback")
            return nil
        }

        if let focused,
           let text = findSelectedTextInAXDescendants(
               startingAt: [focused],
               context: "focusedElement",
               maximumCount: maxDescendantSearchCount,
               childAttributes: axChildAttributeNames,
               deadline: nil
           ) {
            return text
        }

        return getSelectedTextViaAccessibilityWindowSearch(
            appRef: appRef,
            maxDescendantSearchCount: maxDescendantSearchCount
        )
    }

    nonisolated private static func selectedTextNearPoint(_ point: CGPoint,
                                                          appRef: AXUIElement,
                                                          deadline: TimeInterval?) -> String? {
        var hitElement: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(
            appRef,
            Float(point.x),
            Float(point.y),
            &hitElement
        )
        guard hitError == .success, let hitElement else {
            AppLog.debug("TextSelector AX point lookup unavailable err=\(hitError.rawValue)")
            return nil
        }

        if let text = selectedText(from: hitElement) {
            AppLog.debug("TextSelector AX selected text found context=pointElement length=\(text.count)")
            return text
        }

        var current = hitElement
        for ancestorIndex in 1...maxLocalAXAncestorCount {
            guard shouldContinue(until: deadline) else { break }
            let parentResult = copyAXElementAttribute(current, kAXParentAttribute as CFString)
            guard let parent = parentResult.element else { break }
            if let text = selectedText(from: parent) {
                AppLog.debug(
                    "TextSelector AX selected text found context=pointAncestor depth=\(ancestorIndex) length=\(text.count)"
                )
                return text
            }
            current = parent
        }

        guard shouldContinue(until: deadline) else { return nil }
        return findSelectedTextInAXDescendants(
            startingAt: [hitElement],
            context: "pointDescendants",
            maximumCount: maxLocalAXSearchCount,
            childAttributes: axLocalChildAttributeNames,
            deadline: deadline
        )
    }

    nonisolated private static func selectedTextFromFocusedWindow(appRef: AXUIElement) -> String? {
        let windowResult = copyAXElementAttribute(appRef, kAXFocusedWindowAttribute as CFString)
        guard let focusedWindow = windowResult.element else {
            AppLog.debug("TextSelector AX focused window unavailable err=\(windowResult.error.rawValue)")
            return nil
        }
        return selectedText(from: focusedWindow)
    }

    nonisolated private static func getSelectedTextViaAccessibilityWindowSearch(
        appRef: AXUIElement,
        maxDescendantSearchCount: Int
    ) -> String? {
        guard !Task.isCancelled else { return nil }
        let windowResult = copyAXElementAttribute(appRef, kAXFocusedWindowAttribute as CFString)
        if let focusedWindow = windowResult.element {
            if let text = selectedText(from: focusedWindow) {
                return text
            }
            if let text = findSelectedTextInAXDescendants(
                startingAt: [focusedWindow],
                context: "focusedWindow",
                maximumCount: maxDescendantSearchCount,
                childAttributes: axChildAttributeNames,
                deadline: nil
            ) {
                return text
            }
        } else {
            AppLog.debug("TextSelector AX focused window unavailable err=\(windowResult.error.rawValue)")
        }

        guard !Task.isCancelled else { return nil }

        let windows = copyAXChildElements(from: appRef, attribute: kAXWindowsAttribute as CFString)
        guard !windows.isEmpty else {
            AppLog.debug("TextSelector AX windows unavailable")
            return nil
        }

        return findSelectedTextInAXDescendants(
            startingAt: windows,
            context: "windows",
            maximumCount: maxDescendantSearchCount,
            childAttributes: axChildAttributeNames,
            deadline: nil
        )
    }

    nonisolated private static func selectedText(from element: AXUIElement) -> String? {
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

    nonisolated private static func findSelectedTextInAXDescendants(
        startingAt roots: [AXUIElement],
        context: String,
        maximumCount: Int,
        childAttributes: [CFString],
        deadline: TimeInterval?
    ) -> String? {
        var queue = roots
        var index = 0
        var inspectedCount = 0
        var visited = Set<CFHashCode>()

        while index < queue.count,
              inspectedCount < maximumCount,
              shouldContinue(until: deadline) {
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

            for attribute in childAttributes {
                guard shouldContinue(until: deadline) else { break }
                queue.append(contentsOf: copyAXChildElements(from: element, attribute: attribute))
            }
        }

        AppLog.debug(
            "TextSelector AX descendant search stopped context=\(context) inspected=\(inspectedCount) reason=\(stopReason(deadline: deadline))"
        )
        return nil
    }

    nonisolated private static func shouldContinue(until deadline: TimeInterval?) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let deadline else { return true }
        return ProcessInfo.processInfo.systemUptime < deadline
    }

    nonisolated private static func stopReason(deadline: TimeInterval?) -> String {
        if Task.isCancelled { return "cancelled" }
        if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { return "budgetExceeded" }
        return "exhausted"
    }

    nonisolated private static func copyAXElementAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> (error: AXError, element: AXUIElement?) {
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

    nonisolated private static func copyAXChildElements(from element: AXUIElement,
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
        // 轮询中读到我方 ⌘C 产生的 changeCount 后记录于此；恢复前据此区分
        // 「我们的复制」与「用户随后自己的复制」，后者绝不能被快照覆盖。
        var observedChangeCount = oldCount
        defer {
            let currentCount = pb.changeCount
            if currentCount == oldCount {
                // 剪贴板从未变化（复制失败/无选区），无需重写，避免无谓地 bump changeCount。
            } else if observedChangeCount != oldCount, currentCount != observedChangeCount {
                // 在我们读取之后剪贴板又被外部写入（用户自己复制了新内容），保留之。
                AppLog.debug("TextSelector clipboard restore skipped: changed externally count=\(currentCount)")
            } else {
                restorePasteboardSnapshot(snapshot, to: pb)
            }
        }

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
                observedChangeCount = pb.changeCount
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
