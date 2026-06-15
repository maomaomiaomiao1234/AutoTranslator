import Foundation
import CoreGraphics

protocol MouseMonitorDelegate: AnyObject {
    func onSelectionEvent(allowClipboardFallback: Bool)
}

final class MouseMonitor {
    private let dragThresholdSq: Double = 36
    private let selectionDispatchDelay: DispatchTimeInterval = .milliseconds(50)
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var mouseDownPoint: CGPoint?
    private var mouseDraggedSinceDown = false
    private var ignoresCurrentMouseSequence = false
    private var pendingSelectionWorkItem: DispatchWorkItem?

    weak var delegate: MouseMonitorDelegate?
    var shouldIgnoreMouseSequenceStartingAt: ((CGPoint) -> Bool)?

    deinit {
        pendingSelectionWorkItem?.cancel()
        stop()
    }

    func start() {
        guard eventTap == nil else { return }

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
    }

    func stop() {
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
            pendingSelectionWorkItem?.cancel()
            pendingSelectionWorkItem = nil
            mouseDownPoint = event.location
            mouseDraggedSinceDown = false
            ignoresCurrentMouseSequence = shouldIgnoreMouseSequenceStartingAt?(event.location) ?? false
        case .leftMouseDragged:
            guard !ignoresCurrentMouseSequence else { return }
            guard let down = mouseDownPoint else { return }
            let loc = event.location
            let dx = loc.x - down.x
            let dy = loc.y - down.y
            if dx * dx + dy * dy >= dragThresholdSq {
                mouseDraggedSinceDown = true
            }
        case .leftMouseUp:
            guard !ignoresCurrentMouseSequence else {
                mouseDownPoint = nil
                mouseDraggedSinceDown = false
                ignoresCurrentMouseSequence = false
                return
            }
            let clickCount = event.getIntegerValueField(.mouseEventClickState)
            let isSelectionGesture = mouseDraggedSinceDown || clickCount > 1
            mouseDownPoint = nil
            mouseDraggedSinceDown = false
            ignoresCurrentMouseSequence = false
            guard isSelectionGesture else { return }
            scheduleSelectionEvent(allowClipboardFallback: true)
        default:
            break
        }
    }

    private func scheduleSelectionEvent(allowClipboardFallback: Bool) {
        pendingSelectionWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.delegate?.onSelectionEvent(allowClipboardFallback: allowClipboardFallback)
        }

        pendingSelectionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + selectionDispatchDelay, execute: workItem)
    }
}
