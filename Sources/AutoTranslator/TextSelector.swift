import Cocoa
import ApplicationServices
import CoreGraphics

final class TextSelector {
    private let copyInterval: TimeInterval
    private var lastCopyTime: TimeInterval = 0

    init(copyInterval: TimeInterval = 0.4) {
        self.copyInterval = copyInterval
    }

    func getSelectedText(allowClipboardFallback: Bool = false,
                         previousText: String = "") -> String? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier

        // 尝试 Accessibility API
        if let text = getSelectedTextViaAccessibility(pid: pid) {
            return text
        }

        guard allowClipboardFallback else { return nil }
        return getByClipboard(previousText: previousText)
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

    private func getByClipboard(previousText: String) -> String? {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCopyTime < copyInterval { return nil }
        lastCopyTime = now

        let pb = NSPasteboard.general
        let oldText = pb.string(forType: .string)
        let oldCount = pb.changeCount
        simulateCmdC()

        var newText: String? = nil
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.01)
            if pb.changeCount != oldCount {
                newText = pb.string(forType: .string)
                break
            }
        }

        // 恢复旧剪贴板
        if let old = oldText {
            pb.clearContents()
            pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType")], owner: nil)
            pb.setString(old, forType: .string)
        }

        guard let text = newText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text != previousText else { return nil }
        return text
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
