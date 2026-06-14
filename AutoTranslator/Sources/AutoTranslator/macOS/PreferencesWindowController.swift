import Cocoa
import SwiftUI

protocol PreferencesWindowControllerDelegate: AnyObject {
    func preferencesDidSave(backend: String, apiKey: String?, srcLang: String, destLang: String, theme: Theme)
    func preferencesCurrentSourceLang() -> String
    func preferencesCurrentDestLang() -> String
    func preferencesCurrentTheme() -> Theme
}

final class PreferencesWindowController: NSWindowController {

    weak var prefDelegate: PreferencesWindowControllerDelegate?

    private let hostingView: NSHostingView<PreferencesView>
    private var isRootViewLoaded = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "偏好设置"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()

        hostingView = NSHostingView(rootView: PreferencesWindowController.makeView(
            snapshot: PreferencesWindowController.makeSnapshot(prefDelegate: nil),
            onSave: { _ in },
            onClose: {}
        ))

        super.init(window: window)
        window.contentView = hostingView
        reloadRootView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func showWindow(_ sender: Any?) {
        reloadRootViewIfNeeded()
        super.showWindow(sender)
    }

    func showAndFocus() {
        reloadRootViewIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func reloadRootViewIfNeeded() {
        guard window?.isVisible != true || !isRootViewLoaded else { return }
        reloadRootView()
    }

    private func reloadRootView() {
        hostingView.rootView = Self.makeView(
            snapshot: Self.makeSnapshot(prefDelegate: prefDelegate),
            onSave: { [weak self] payload in
                self?.save(payload)
            },
            onClose: { [weak self] in
                self?.window?.performClose(nil)
            }
        )
        isRootViewLoaded = true
    }

    private static func makeSnapshot(prefDelegate: PreferencesWindowControllerDelegate?) -> PreferencesSnapshot {
        let backend = ConfigStore.shared.get(.backend) ?? "llm"
        let apiKey = ConfigStore.shared.get(.deepseekKey) ?? ConfigStore.shared.get(.llmKey) ?? ""
        let model = ConfigStore.shared.get(.llmModel)
            ?? ProcessInfo.processInfo.environment["LLM_MODEL"]
            ?? ""
        let baseURL = ConfigStore.shared.get(.llmBaseURL)
            ?? ProcessInfo.processInfo.environment["LLM_BASE_URL"]
            ?? ""
        let source = prefDelegate?.preferencesCurrentSourceLang()
            ?? ConfigStore.shared.get(.srcLang)
            ?? Languages.defaultSourceCode
        let target = prefDelegate?.preferencesCurrentDestLang()
            ?? ConfigStore.shared.get(.destLang)
            ?? Languages.defaultTargetCode
        let theme = prefDelegate?.preferencesCurrentTheme()
            ?? Theme.from(rawValue: ConfigStore.shared.get(.theme))

        return PreferencesSnapshot(
            backend: backend == "google" ? "google" : "llm",
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            sourceLang: Languages.nameByCode[source] == nil ? Languages.defaultSourceCode : source,
            targetLang: (target == "auto" || Languages.nameByCode[target] == nil) ? Languages.defaultTargetCode : target,
            theme: theme
        )
    }

    private static func makeView(
        snapshot: PreferencesSnapshot,
        onSave: @escaping (PreferencesSavePayload) -> Void,
        onClose: @escaping () -> Void
    ) -> PreferencesView {
        PreferencesView(
            snapshot: snapshot,
            configPath: ConfigStore.shared.configFileURL.path,
            onSave: onSave,
            onClose: onClose
        )
    }

    private func save(_ payload: PreferencesSavePayload) {
        var updates: [ConfigStore.Key: String?] = [
            .backend: payload.backend,
            .srcLang: payload.sourceLang,
            .destLang: payload.targetLang,
            .theme: payload.theme.rawValue,
            .llmModel: payload.model,
            .llmBaseURL: payload.baseURL,
        ]

        if let apiKey = payload.apiKey {
            updates[.deepseekKey] = apiKey
            updates[.llmKey] = apiKey
        } else {
            updates[.deepseekKey] = nil
            updates[.llmKey] = nil
        }

        ConfigStore.shared.update(updates)
        prefDelegate?.preferencesDidSave(
            backend: payload.backend,
            apiKey: payload.apiKey,
            srcLang: payload.sourceLang,
            destLang: payload.targetLang,
            theme: payload.theme
        )
        isRootViewLoaded = false
    }
}
