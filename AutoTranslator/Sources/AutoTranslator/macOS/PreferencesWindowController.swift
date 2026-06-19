import Cocoa
import SwiftUI

protocol PreferencesWindowControllerDelegate: AnyObject {
    func preferencesDidSave(
        backend: String,
        apiKey: String?,
        srcLang: String,
        destLang: String,
        theme: Theme,
        floatingWindowMode: FloatingWindowMode
    )
    func preferencesCurrentSourceLang() -> String
    func preferencesCurrentDestLang() -> String
    func preferencesCurrentTheme() -> Theme
    func preferencesCurrentFloatingWindowMode() -> FloatingWindowMode
}

final class PreferencesWindowController: NSWindowController {

    weak var prefDelegate: PreferencesWindowControllerDelegate?

    private let hostingView: NSHostingView<PreferencesView>
    private var isRootViewLoaded = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 740),
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
        let apiKey = ConfigStore.shared.get(.deepseekKey)
            ?? ConfigStore.shared.get(.llmKey)
            ?? ConfigStore.shared.get(.dashscopeKey)
            ?? ""
        let model = ConfigStore.shared.get(.llmModel)
            ?? ProcessInfo.processInfo.environment["LLM_MODEL"]
            ?? ""
        let baseURL = ConfigStore.shared.get(.llmBaseURL)
            ?? ProcessInfo.processInfo.environment["LLM_BASE_URL"]
            ?? ""
        let ttsApiKey = ConfigStore.shared.get(.ttsKey)
            ?? ProcessInfo.processInfo.environment["TTS_API_KEY"]
            ?? ""
        let ttsAutoPlay = Self.boolValue(
            ConfigStore.shared.get(.ttsAutoPlay)
                ?? ProcessInfo.processInfo.environment["TTS_AUTO_PLAY"]
        )
        let ttsModel = SpeechService.normalizedStoredModel(
            ConfigStore.shared.get(.ttsModel)
                ?? ProcessInfo.processInfo.environment["TTS_MODEL"]
        )
        let ttsVoice = SpeechService.normalizedStoredVoice(
            ConfigStore.shared.get(.ttsVoice)
                ?? ProcessInfo.processInfo.environment["TTS_VOICE"]
        )
        let ttsBaseURL = SpeechService.normalizedStoredEndpoint(
            ConfigStore.shared.get(.ttsBaseURL)
                ?? ProcessInfo.processInfo.environment["TTS_BASE_URL"]
        )
        let source = prefDelegate?.preferencesCurrentSourceLang()
            ?? ConfigStore.shared.get(.srcLang)
            ?? Languages.defaultSourceCode
        let target = prefDelegate?.preferencesCurrentDestLang()
            ?? ConfigStore.shared.get(.destLang)
            ?? Languages.defaultTargetCode
        let theme = prefDelegate?.preferencesCurrentTheme()
            ?? Theme.from(rawValue: ConfigStore.shared.get(.theme))
        let floatingWindowMode = prefDelegate?.preferencesCurrentFloatingWindowMode()
            ?? FloatingWindowMode.from(rawValue: ConfigStore.shared.get(.floatingWindowMode))

        return PreferencesSnapshot(
            backend: TranslationBackend.isValid(backend) ? backend : "llm",
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            ttsApiKey: ttsApiKey,
            ttsAutoPlay: ttsAutoPlay,
            ttsModel: ttsModel,
            ttsVoice: ttsVoice,
            ttsBaseURL: ttsBaseURL,
            sourceLang: Languages.nameByCode[source] == nil ? Languages.defaultSourceCode : source,
            targetLang: (target == "auto" || Languages.nameByCode[target] == nil) ? Languages.defaultTargetCode : target,
            theme: theme,
            floatingWindowMode: floatingWindowMode
        )
    }

    private static func boolValue(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value)
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
            .ttsKey: payload.ttsApiKey,
            .ttsAutoPlay: payload.ttsAutoPlay ? "true" : nil,
            .ttsModel: payload.ttsModel,
            .ttsVoice: payload.ttsVoice,
            .ttsBaseURL: payload.ttsBaseURL,
            .floatingWindowMode: payload.floatingWindowMode.rawValue,
        ]

        if let apiKey = payload.apiKey {
            updates[.deepseekKey] = apiKey
            updates[.llmKey] = apiKey
            updates[.dashscopeKey] = apiKey
        } else {
            updates[.deepseekKey] = nil
            updates[.llmKey] = nil
            updates[.dashscopeKey] = nil
        }

        ConfigStore.shared.update(updates)
        prefDelegate?.preferencesDidSave(
            backend: payload.backend,
            apiKey: payload.apiKey,
            srcLang: payload.sourceLang,
            destLang: payload.targetLang,
            theme: payload.theme,
            floatingWindowMode: payload.floatingWindowMode
        )
        isRootViewLoaded = false
    }
}
