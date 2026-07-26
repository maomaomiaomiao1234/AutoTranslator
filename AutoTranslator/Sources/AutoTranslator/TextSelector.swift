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

    struct PasteboardItemSnapshot {
        let dataByType: [NSPasteboard.PasteboardType: Data]
    }

    struct PasteboardSnapshot {
        let items: [PasteboardItemSnapshot]
        let fallbackString: String?
        let hadContents: Bool
    }

    private let copyInterval: TimeInterval
    private let copyPollIntervalNs: UInt64
    private let maxCopyPollCount: Int
    private let copyGraceWindow: TimeInterval
    private let copyGracePollIntervalNs: UInt64
    private let maxSnapshotBytes: Int
    private let maxAXDescendantSearchCount: Int
    private let accessibilityLookupGate = AccessibilityLookupGate()
    private var lastCopyTime: TimeInterval = 0
    private var didWarnPasteboardAccessDenied = false

    /// - copyGraceWindow: 自合成 ⌘C 发出起，观察目标应用「迟到写入剪贴板」的总时长。
    /// - maxSnapshotBytes: 剪贴板快照的累计字节预算，超出即放弃整条剪贴板回退。
    init(copyInterval: TimeInterval = 0.12,
         copyPollInterval: TimeInterval = 0.01,
         maxCopyPollCount: Int = 20,
         copyGraceWindow: TimeInterval = 1.5,
         copyGracePollInterval: TimeInterval = 0.05,
         maxSnapshotBytes: Int = 64 * 1024 * 1024,
         maxAXDescendantSearchCount: Int = 180) {
        self.copyInterval = copyInterval
        self.copyPollIntervalNs = UInt64(copyPollInterval * 1_000_000_000)
        self.maxCopyPollCount = maxCopyPollCount
        self.copyGraceWindow = copyGraceWindow
        self.copyGracePollIntervalNs = UInt64(copyGracePollInterval * 1_000_000_000)
        self.maxSnapshotBytes = maxSnapshotBytes
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

        let pb = NSPasteboard.general
        guard pasteboardAccessPermitted(pb) else { return nil }
        guard !Self.pasteboardHoldsUnrestorableContent(pb) else { return nil }
        guard let snapshot = capturePasteboardSnapshot(pb) else { return nil }
        // 剪贴板有内容却一个字节都读不出来（macOS 15.4+ 剪贴板隐私未放行等）：
        // 一旦 ⌘C 覆盖便无从恢复。此时直接放弃，绝不拿用户剪贴板冒险。
        if snapshot.hadContents,
           snapshot.fallbackString == nil,
           snapshot.items.allSatisfy({ $0.dataByType.isEmpty }) {
            AppLog.debug("TextSelector clipboard skipped: snapshot unreadable (pasteboard privacy?)")
            return nil
        }

        lastCopyTime = ProcessInfo.processInfo.systemUptime

        let oldCount = pb.changeCount
        // 轮询中读到我方 ⌘C 产生的 changeCount 后记录于此；恢复前据此区分
        // 「我们的复制」与「用户随后自己的复制」，后者绝不能被快照覆盖。
        var observedChangeCount = oldCount
        // 宽限期内变化伴随用户按键/右键时置位：内容归属不明，既不使用也不写回快照。
        var suppressRestore = false
        defer {
            let currentCount = pb.changeCount
            if suppressRestore {
                AppLog.debug("TextSelector clipboard restore suppressed: change attributed to user count=\(currentCount)")
            } else if currentCount == oldCount {
                // 剪贴板从未变化（复制失败/无选区），无需重写，避免无谓地 bump changeCount。
            } else if observedChangeCount != oldCount, currentCount != observedChangeCount {
                // 在我们读取之后剪贴板又被外部写入（用户自己复制了新内容），保留之。
                AppLog.debug("TextSelector clipboard restore skipped: changed externally count=\(currentCount)")
            } else {
                restorePasteboardSnapshot(snapshot, to: pb)
            }
        }

        AppLog.debug("TextSelector clipboard copy requested oldChangeCount=\(oldCount) hadContents=\(snapshot.hadContents)")
        let postUptime = ProcessInfo.processInfo.systemUptime
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

        // 宽限期：快速轮询超时 ≠ 复制没发生。忙碌应用/远程桌面可能数百毫秒后才处理
        // 我们的 ⌘C 并写入剪贴板；旧实现此时已带着「未变化、不重写」的结论返回，
        // 迟到的复制会把用户剪贴板永久替换（数据丢失缺陷）。这里降频继续观察：
        // - 变化且期间无用户按键/右键（deliberateUserInputOccurred）→ 判定为我们的
        //   迟到复制：照常读取文本，并经 defer 恢复快照；
        // - 变化但检测到用户输入 → 可能是用户自己的复制：内容不用，快照也不写回；
        // - 到期仍无变化 → 保持原状返回。晚于宽限期才落盘的复制仍拦不住，属残余风险。
        if newText == nil {
            let graceDeadline = postUptime + copyGraceWindow
            while ProcessInfo.processInfo.systemUptime < graceDeadline {
                if Task.isCancelled {
                    if pb.changeCount != oldCount, Self.deliberateUserInputOccurred(since: postUptime) {
                        suppressRestore = true
                    }
                    AppLog.debug("TextSelector clipboard cancelled during grace window suppressRestore=\(suppressRestore)")
                    return nil
                }
                try? await Task.sleep(nanoseconds: copyGracePollIntervalNs)
                guard pb.changeCount != oldCount else { continue }
                if Self.deliberateUserInputOccurred(since: postUptime) {
                    suppressRestore = true
                    AppLog.debug("TextSelector clipboard grace change attributed to user; pasteboard left untouched")
                    return nil
                }
                observedChangeCount = pb.changeCount
                newText = pb.string(forType: .string)
                AppLog.debug("TextSelector clipboard changed during grace elapsed=\(Self.seconds(ProcessInfo.processInfo.systemUptime - postUptime))s newChangeCount=\(pb.changeCount)")
                break
            }
        }

        guard let text = newText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            AppLog.debug("TextSelector clipboard failed: no text after polls=\(pollIndex) graceWindow=\(Self.seconds(copyGraceWindow))s")
            return nil
        }
        return text
    }

    /// 恢复写回时附带的 transient 标记（nspasteboard.org 社区约定）：
    /// 提示剪贴板历史工具不要把这次「恢复原内容」记录成一条新历史。
    nonisolated private static let transientMarkerType =
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// 出现下列类型时整体放弃剪贴板回退：
    /// - ConcealedType：密码管理器的隐藏内容约定。不把密码读进本进程内存；
    ///   且恢复会产生新的 changeCount 代际，令密码管理器「N 秒后自动清除」失效。
    /// - 文件承诺（file promise）：数据由源 App 惰性提供，快照拿不到、恢复也还不回去。
    nonisolated private static let unrestorablePasteboardTypeIdentifiers: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "Apple files promise pasteboard type", // 旧式 NSFilesPromisePboardType
    ]

    /// macOS 15.4+「从其他应用粘贴」权限被明确拒绝时，快照必然读不到内容，
    /// 而读不到快照还发 ⌘C 就意味着必然丢失用户剪贴板——直接跳过整条回退路径。
    @MainActor
    private func pasteboardAccessPermitted(_ pb: NSPasteboard) -> Bool {
        if #available(macOS 15.4, *) {
            guard pb.accessBehavior == .alwaysDeny else { return true }
            AppLog.debug("TextSelector clipboard skipped: pasteboard access denied by system setting")
            if !didWarnPasteboardAccessDenied {
                didWarnPasteboardAccessDenied = true
                NotificationManager.shared.post(
                    title: "剪贴板取词不可用",
                    body: "系统设置拒绝了 AutoTranslator 读取剪贴板。可在 系统设置 > 隐私与安全性 > 从其他应用粘贴 中允许；当前仅使用辅助功能取词。"
                )
            }
            return false
        }
        return true
    }

    @MainActor
    static func pasteboardHoldsUnrestorableContent(_ pb: NSPasteboard) -> Bool {
        var typeIdentifiers = Set((pb.types ?? []).map(\.rawValue))
        for item in pb.pasteboardItems ?? [] {
            typeIdentifiers.formUnion(item.types.map(\.rawValue))
        }
        let blocked = typeIdentifiers.intersection(unrestorablePasteboardTypeIdentifiers)
        guard blocked.isEmpty else {
            AppLog.debug("TextSelector clipboard skipped: unrestorable content types=\(blocked.sorted().joined(separator: ","))")
            return true
        }
        return false
    }

    /// 自我方合成 ⌘C（postUptime 时刻）以来，是否出现过可能产生「用户自己复制」的输入。
    /// 只统计按键与右键：用户亲自 ⌘C 必有 keyDown，右键菜单拷贝始于 rightMouseDown；
    /// 普通左键不算——连续划词/三连击必然伴随左键，而宽限期（秒级）内经菜单栏完成
    /// 拷贝几乎不可能。实现用 CGEventSource 的聚合时间戳查询：无需键盘事件 tap，
    /// 也读不到任何具体按键内容。我方合成 keyDown 恰发生在 postUptime，因此
    /// 「距最近一次 keyDown 的时间」明显小于「距 post 的时间」即说明其后另有真实输入。
    nonisolated private static func deliberateUserInputOccurred(since postUptime: TimeInterval) -> Bool {
        let elapsed = ProcessInfo.processInfo.systemUptime - postUptime
        let slack: TimeInterval = 0.05
        for eventType in [CGEventType.keyDown, .rightMouseDown] {
            let sinceLast = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: eventType
            )
            if sinceLast < elapsed - slack {
                return true
            }
        }
        return false
    }

    /// 快照剪贴板全部 item 的全部 flavor。累计字节数超过 maxSnapshotBytes 时返回 nil：
    /// 主线程物化超大数据会卡顿；而被截断的快照一旦用于恢复，等于丢弃其余表示。
    /// 返回 nil 时调用方应放弃整条剪贴板回退（此刻尚未发 ⌘C，无任何副作用）。
    @MainActor
    func capturePasteboardSnapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        let items = pasteboard.pasteboardItems ?? []
        var snapshots: [PasteboardItemSnapshot] = []
        snapshots.reserveCapacity(items.count)
        var totalBytes = 0
        for item in items {
            var dataByType: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                totalBytes += data.count
                guard totalBytes <= maxSnapshotBytes else {
                    AppLog.debug("TextSelector clipboard skipped: snapshot over budget bytes>=\(totalBytes) limit=\(maxSnapshotBytes)")
                    return nil
                }
                dataByType[type] = data
            }
            snapshots.append(PasteboardItemSnapshot(dataByType: dataByType))
        }
        return PasteboardSnapshot(
            items: snapshots,
            fallbackString: pasteboard.string(forType: .string),
            hadContents: !items.isEmpty
        )
    }

    /// 把快照写回剪贴板，transient 标记逐个挂在真实恢复的 item 上。
    /// 不再使用旧的 declareTypes + writeObjects 组合——那会先产生一个声明了 .string
    /// 却无数据的 item 0，按「第一个含该类型的 item」读取的程序会拿到空剪贴板。
    @MainActor
    func restorePasteboardSnapshot(_ snapshot: PasteboardSnapshot, to pb: NSPasteboard) {
        let restoredItems = snapshot.items.compactMap { itemSnapshot -> NSPasteboardItem? in
            guard !itemSnapshot.dataByType.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (type, data) in itemSnapshot.dataByType {
                item.setData(data, forType: type)
            }
            item.setData(Data(), forType: Self.transientMarkerType)
            return item
        }

        if !restoredItems.isEmpty {
            pb.clearContents()
            pb.writeObjects(restoredItems)
            return
        }

        if let fallbackString = snapshot.fallbackString {
            let item = NSPasteboardItem()
            item.setString(fallbackString, forType: .string)
            item.setData(Data(), forType: Self.transientMarkerType)
            pb.clearContents()
            pb.writeObjects([item])
            return
        }

        // 快照里没有任何可恢复的数据：保持现状、不清空。「原剪贴板确实为空」时留下
        // 选中文本只是小瑕疵；反之若空快照源于读取被拒（剪贴板隐私权限等），
        // 清空会销毁用户仍在使用的内容。两害相权取其轻。
        AppLog.debug("TextSelector clipboard restore skipped: empty snapshot")
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
