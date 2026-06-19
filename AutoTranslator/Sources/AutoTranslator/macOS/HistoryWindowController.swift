import AppKit
import SwiftUI

final class HistoryWindowController: NSWindowController {
    private let hostingView: NSHostingView<TranslationHistoryView>

    init(store: TranslationHistoryStore) {
        let rootView = TranslationHistoryView(store: store)
        hostingView = NSHostingView(rootView: rootView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "翻译历史"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 500)
        window.contentView = hostingView
        window.center()

        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func showAndFocus() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
