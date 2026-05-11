import Foundation
import CoreGraphics

protocol MouseMonitorDelegate: AnyObject {
    func onSelectionEvent(allowClipboardFallback: Bool)
}

final class MouseMonitor {
    private let dragThresholdSq: Double = 36
    private let selectionDispatchDelay: DispatchTimeInterval = .milliseconds(50)
    private var eventTap: CFMachPort?
    private var mouseDownPoint: CGPoint?
    private var mouseDraggedSinceDown = false
    private var pendingSelectionWorkItem: DispatchWorkItem?

    weak var delegate: MouseMonitorDelegate?

    deinit {
        pendingSelectionWorkItem?.cancel()
        stop()
    }

    func start() {
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
            fputs("[AutoTranslator] 无法创建 EventTap\n", stderr)
            return
        }

        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .leftMouseDown:
            pendingSelectionWorkItem?.cancel()
            pendingSelectionWorkItem = nil
            mouseDownPoint = event.location
            mouseDraggedSinceDown = false
        case .leftMouseDragged:
            guard let down = mouseDownPoint else { return }
            let loc = event.location
            let dx = loc.x - down.x
            let dy = loc.y - down.y
            if dx * dx + dy * dy >= dragThresholdSq {
                mouseDraggedSinceDown = true
            }
        case .leftMouseUp:
            let clickCount = event.getIntegerValueField(.mouseEventClickState)
            let allow = mouseDraggedSinceDown || clickCount > 1
            mouseDownPoint = nil
            mouseDraggedSinceDown = false
            scheduleSelectionEvent(allowClipboardFallback: allow)
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
