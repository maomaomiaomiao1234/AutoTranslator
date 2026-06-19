import Foundation
import CoreGraphics

protocol MouseMonitorDelegate: AnyObject {
    func onSelectionEvent(allowClipboardFallback: Bool, allowDeepAccessibilitySearch: Bool)
}

final class MouseMonitor {
    private let dragThresholdSq: Double = 36
    private let selectionDispatchDelay: DispatchTimeInterval = .milliseconds(50)
    private let selectionProbeDispatchDelay: DispatchTimeInterval = .milliseconds(120)
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseDownPoint: CGPoint?
    private var mouseDraggedSinceDown = false
    private var dragEventCount = 0
    private var maxDragDistanceSq: Double = 0
    private var ignoresCurrentMouseSequence = false
    private var pendingSelectionWorkItem: DispatchWorkItem?

    weak var delegate: MouseMonitorDelegate?
    var shouldIgnoreMouseSequenceStartingAt: ((CGPoint) -> Bool)?

    deinit {
        pendingSelectionWorkItem?.cancel()
        stop()
    }

    func start() {
        guard eventTap == nil else {
            AppLog.debug("SelectionMonitor start skipped: eventTap already active")
            return
        }

        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { (_proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<MouseMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handleEvent(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            AppLog.error("无法创建 EventTap")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLog.debug("SelectionMonitor started")
    }

    func stop() {
        if pendingSelectionWorkItem != nil {
            AppLog.debug("SelectionMonitor cancel pending dispatch on stop")
        }
        pendingSelectionWorkItem?.cancel()
        pendingSelectionWorkItem = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        eventTap = nil
        AppLog.debug("SelectionMonitor stopped")
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 系统在高负载或用户输入抢占时会主动禁用 listen-only tap，
            // 必须重新启用，否则划词会静默失效直到 App 重启。
            guard let tap = eventTap else { return }
            CGEvent.tapEnable(tap: tap, enable: true)
            AppLog.error("EventTap 被系统禁用 (type=\(type.rawValue))，已重新启用")
        case .leftMouseDown:
            if pendingSelectionWorkItem != nil {
                AppLog.debug("SelectionMonitor cancel pending dispatch on new mouseDown")
            }
            pendingSelectionWorkItem?.cancel()
            pendingSelectionWorkItem = nil
            mouseDownPoint = event.location
            mouseDraggedSinceDown = false
            dragEventCount = 0
            maxDragDistanceSq = 0
            ignoresCurrentMouseSequence = shouldIgnoreMouseSequenceStartingAt?(event.location) ?? false
            if ignoresCurrentMouseSequence {
                AppLog.debug("Selection gesture ignored from mouseDown at \(Self.pointDescription(event.location))")
            }
        case .leftMouseDragged:
            guard !ignoresCurrentMouseSequence else { return }
            guard let down = mouseDownPoint else { return }
            let loc = event.location
            let dx = loc.x - down.x
            let dy = loc.y - down.y
            let distanceSq = dx * dx + dy * dy
            dragEventCount += 1
            maxDragDistanceSq = max(maxDragDistanceSq, distanceSq)
            if !mouseDraggedSinceDown, distanceSq >= dragThresholdSq {
                mouseDraggedSinceDown = true
                AppLog.debug("Selection drag threshold reached distanceSq=\(Self.rounded(distanceSq))")
            }
        case .leftMouseUp:
            guard !ignoresCurrentMouseSequence else {
                AppLog.debug(
                    "Selection gesture dropped on mouseUp: ignored sequence dragEvents=\(dragEventCount) maxDistanceSq=\(Self.rounded(maxDragDistanceSq))"
                )
                mouseDownPoint = nil
                mouseDraggedSinceDown = false
                dragEventCount = 0
                maxDragDistanceSq = 0
                ignoresCurrentMouseSequence = false
                return
            }
            let clickCount = event.getIntegerValueField(.mouseEventClickState)
            let wasDragged = mouseDraggedSinceDown
            let isSelectionGesture = wasDragged || clickCount > 1
            let mouseUpDistanceSq = mouseUpDistanceSq(from: event.location)
            let observedDragEventCount = dragEventCount
            let observedMaxDragDistanceSq = maxDragDistanceSq
            mouseDownPoint = nil
            mouseDraggedSinceDown = false
            dragEventCount = 0
            maxDragDistanceSq = 0
            ignoresCurrentMouseSequence = false
            guard isSelectionGesture else {
                AppLog.debug(
                    "Selection gesture inconclusive on mouseUp: probing AX only clickCount=\(clickCount) dragEvents=\(observedDragEventCount) maxDistanceSq=\(Self.rounded(observedMaxDragDistanceSq)) mouseUpDistanceSq=\(Self.rounded(mouseUpDistanceSq)) thresholdSq=\(Self.rounded(dragThresholdSq))"
                )
                scheduleSelectionEvent(
                    allowClipboardFallback: false,
                    allowDeepAccessibilitySearch: false,
                    delay: selectionProbeDispatchDelay
                )
                return
            }
            AppLog.debug(
                "Selection gesture accepted clickCount=\(clickCount) dragged=\(wasDragged) dragEvents=\(observedDragEventCount) maxDistanceSq=\(Self.rounded(observedMaxDragDistanceSq))"
            )
            scheduleSelectionEvent(
                allowClipboardFallback: true,
                allowDeepAccessibilitySearch: true,
                delay: selectionDispatchDelay
            )
        default:
            break
        }
    }

    private func mouseUpDistanceSq(from location: CGPoint) -> Double {
        guard let down = mouseDownPoint else { return 0 }
        let dx = location.x - down.x
        let dy = location.y - down.y
        return dx * dx + dy * dy
    }

    private func scheduleSelectionEvent(allowClipboardFallback: Bool,
                                        allowDeepAccessibilitySearch: Bool,
                                        delay: DispatchTimeInterval) {
        if pendingSelectionWorkItem != nil {
            AppLog.debug("SelectionMonitor replace pending dispatch")
        }
        pendingSelectionWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            AppLog.debug("SelectionMonitor dispatch selection event allowClipboardFallback=\(allowClipboardFallback) allowDeepAX=\(allowDeepAccessibilitySearch)")
            self?.delegate?.onSelectionEvent(
                allowClipboardFallback: allowClipboardFallback,
                allowDeepAccessibilitySearch: allowDeepAccessibilitySearch
            )
        }

        pendingSelectionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private static func pointDescription(_ point: CGPoint) -> String {
        "(\(rounded(point.x)),\(rounded(point.y)))"
    }

    private static func rounded(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
