import AppKit
import CoreGraphics
import Testing
@testable import AutoTranslator

@MainActor
private final class SelectionEventRecorder: MouseMonitorDelegate {
    var invalidationCount = 0
    var clipboardPermissions: [Bool] = []
    var points: [CGPoint] = []

    func onSelectionInvalidated() {
        invalidationCount += 1
    }

    func onSelectionEvent(allowClipboardFallback: Bool,
                          allowDeepAccessibilitySearch: Bool,
                          selectionPoint: CGPoint) {
        clipboardPermissions.append(allowClipboardFallback)
        points.append(selectionPoint)
    }
}

@MainActor
struct MouseMonitorReliabilityTests {
    private func event(_ type: CGEventType, x: CGFloat, y: CGFloat = 200,
                       clickCount: Int64 = 1) throws -> CGEvent {
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: type,
                                        mouseCursorPosition: CGPoint(x: x, y: y),
                                        mouseButton: .left))
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        return event
    }

    @Test
    func dragStillTriggersCopyWhenIntermediateDragEventsAreMissing() async throws {
        let monitor = MouseMonitor()
        let recorder = SelectionEventRecorder()
        monitor.delegate = recorder
        monitor.handleEvent(type: .leftMouseDown, event: try event(.leftMouseDown, x: 100))
        monitor.handleEvent(type: .leftMouseUp, event: try event(.leftMouseUp, x: 180))
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.clipboardPermissions == [true])
        #expect(recorder.points == [CGPoint(x: 180, y: 200)])
    }

    @Test
    func stopClearsIgnoredGestureBeforeMonitoringResumes() async throws {
        let monitor = MouseMonitor()
        let recorder = SelectionEventRecorder()
        monitor.delegate = recorder
        monitor.shouldIgnoreMouseSequenceStartingAt = { _ in true }
        monitor.handleEvent(type: .leftMouseDown, event: try event(.leftMouseDown, x: 100))
        monitor.stop()
        monitor.shouldIgnoreMouseSequenceStartingAt = { _ in false }
        // A resumed tap may receive only the up half of a double click.
        monitor.handleEvent(type: .leftMouseUp,
                            event: try event(.leftMouseUp, x: 100, clickCount: 2))
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.clipboardPermissions == [true])
    }

    @Test
    func disabledTapDiscardsPendingSelection() async throws {
        let monitor = MouseMonitor()
        let recorder = SelectionEventRecorder()
        monitor.delegate = recorder
        monitor.handleEvent(type: .leftMouseDown, event: try event(.leftMouseDown, x: 100))
        monitor.handleEvent(type: .leftMouseUp,
                            event: try event(.leftMouseUp, x: 100, clickCount: 2))
        monitor.handleEvent(type: .tapDisabledByTimeout,
                            event: try event(.leftMouseUp, x: 100))
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.clipboardPermissions.isEmpty)
    }

    @Test
    func newMouseDownInvalidatesLookupBeforeItsMouseUp() throws {
        let monitor = MouseMonitor()
        let recorder = SelectionEventRecorder()
        monitor.delegate = recorder
        monitor.handleEvent(type: .leftMouseDown, event: try event(.leftMouseDown, x: 100))
        #expect(recorder.invalidationCount == 1)
        monitor.handleEvent(type: .leftMouseUp,
                            event: try event(.leftMouseUp, x: 160))
        monitor.handleEvent(type: .leftMouseDown, event: try event(.leftMouseDown, x: 200))
        #expect(recorder.invalidationCount == 2)
        #expect(recorder.clipboardPermissions.isEmpty)
    }

    @Test
    func rapidSelectionsDispatchOnlyTheLatestGesture() async throws {
        let monitor = MouseMonitor()
        let recorder = SelectionEventRecorder()
        monitor.delegate = recorder
        for index in 0..<100 {
            let x = CGFloat(index * 10)
            monitor.handleEvent(type: .leftMouseDown, event: try event(.leftMouseDown, x: x))
            monitor.handleEvent(type: .leftMouseUp, event: try event(.leftMouseUp, x: x + 80))
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.clipboardPermissions == [true])
        #expect(recorder.points == [CGPoint(x: 1070, y: 200)])
    }

    @Test
    func ordinaryClickAndSmallJitterDoNotEnableCopy() async throws {
        let monitor = MouseMonitor()
        let recorder = SelectionEventRecorder()
        monitor.delegate = recorder
        monitor.handleEvent(type: .leftMouseDown, event: try event(.leftMouseDown, x: 100))
        monitor.handleEvent(type: .leftMouseUp, event: try event(.leftMouseUp, x: 102))
        try await Task.sleep(for: .milliseconds(200))
        #expect(recorder.clipboardPermissions == [false])
    }
}

struct SelectionScreenGeometryTests {
    @Test
    func floatingWindowDoesNotCreateAMirroredBlindSpot() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let floatingFrame = CGRect(x: 500, y: 600, width: 400, height: 200)
        let actualWindowPoint = SelectionScreenGeometry.appKitPoint(
            fromQuartz: CGPoint(x: 600, y: 200), primaryScreenFrame: primary
        )
        let webpagePoint = SelectionScreenGeometry.appKitPoint(
            fromQuartz: CGPoint(x: 600, y: 700), primaryScreenFrame: primary
        )
        #expect(floatingFrame.contains(actualWindowPoint))
        #expect(!floatingFrame.contains(webpagePoint))
    }

    @Test
    func upperAndLeftDisplaysUseThePrimaryScreenOrigin() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        #expect(SelectionScreenGeometry.appKitPoint(
            fromQuartz: CGPoint(x: 200, y: -300), primaryScreenFrame: primary
        ) == CGPoint(x: 200, y: 1200))
        #expect(SelectionScreenGeometry.appKitPoint(
            fromQuartz: CGPoint(x: -300, y: 200), primaryScreenFrame: primary
        ) == CGPoint(x: -300, y: 700))
    }

    @Test
    func normalPageNearBottomIsNotMistakenForMenuBar() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let pagePoint = SelectionScreenGeometry.appKitPoint(
            fromQuartz: CGPoint(x: 100, y: 890), primaryScreenFrame: primary
        )
        let menuPoint = SelectionScreenGeometry.appKitPoint(
            fromQuartz: CGPoint(x: 100, y: 10), primaryScreenFrame: primary
        )
        #expect(visible.contains(pagePoint))
        #expect(!visible.contains(menuPoint))
    }
}

/// 模拟复制只写私有剪贴板；不合成系统按键、不触碰用户剪贴板。
@MainActor
struct SelectionClipboardReliabilityTests {
    @Test
    func consecutiveCopiesWaitForRateLimitAndRestoreOriginalContents() async throws {
        let selector = TextSelector(copyInterval: 0.12)
        let pb = NSPasteboard(name: .init("SelectionTests.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.setString("原剪贴板", forType: .string)
        for index in 0..<5 {
            let expected = "选区 \(index)"
            let text = await selector.getByClipboard(from: pb, copy: {
                pb.clearContents()
                pb.setString(expected, forType: .string)
            })
            #expect(text == expected)
            #expect(pb.string(forType: .string) == "原剪贴板")
        }
    }

    @Test
    func cancelledRequestDoesNotSendCopyOrModifyPasteboard() async throws {
        let selector = TextSelector()
        let pb = NSPasteboard(name: .init("SelectionTests.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.setString("原剪贴板", forType: .string)
        var copyCount = 0
        let task = Task { @MainActor in
            await selector.getByClipboard(from: pb, copy: { copyCount += 1 })
        }
        task.cancel()
        #expect(await task.value == nil)
        #expect(copyCount == 0)
        #expect(pb.string(forType: .string) == "原剪贴板")
    }

    @Test
    func changedSourceDuringRateLimitDoesNotCopyFromAnotherApp() async throws {
        let selector = TextSelector(copyInterval: 0.12)
        let pb = NSPasteboard(name: .init("SelectionTests.\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.setString("原剪贴板", forType: .string)
        _ = await selector.getByClipboard(from: pb, copy: {
            pb.clearContents()
            pb.setString("首次选区", forType: .string)
        })
        var sourceChecks = 0
        var copyCount = 0
        let text = await selector.getByClipboard(from: pb, isSourceCurrent: {
            sourceChecks += 1
            return sourceChecks == 1
        }, copy: { copyCount += 1 })
        #expect(text == nil)
        #expect(copyCount == 0)
        #expect(pb.string(forType: .string) == "原剪贴板")
    }
}
