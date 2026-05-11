import Cocoa
import ApplicationServices
import CoreGraphics

final class TextSelector {
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
        let oldText = pb.string(forType: .string)
        let oldCount = pb.changeCount
        defer { restoreClipboardText(oldText) }

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
    private func restoreClipboardText(_ oldText: String?) {
        guard let oldText else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType")], owner: nil)
        pb.setString(oldText, forType: .string)
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
