import AppKit
import Combine
import SwiftUI
import Translation

/// 把 Apple `Translation` 框架（强绑定 SwiftUI 的 `TranslationSession`）桥接到本项目的
/// 普通 async 翻译世界。
///
/// 框架只能经 `.translationTask` 视图修饰符拿到 `TranslationSession`，故这里维护一个
/// 隐藏的 SwiftUI 宿主视图（嵌在不可见的 1×1 窗口里）：当配置变化时，SwiftUI 会回送一个
/// 新 session，我们用 continuation 把它交给等待中的翻译调用。相同语言对会复用已有 session。
@available(macOS 15.0, *)
final class AppleTranslationBridge {

    static let shared = AppleTranslationBridge()

    /// 等待 session 的一次性包装：保证 continuation 只被恢复一次（deliver 与超时二选一）。
    private final class Waiter {
        private var continuation: CheckedContinuation<TranslationSession, Error>?
        init(_ continuation: CheckedContinuation<TranslationSession, Error>) {
            self.continuation = continuation
        }
        func resume(_ session: TranslationSession) {
            continuation?.resume(returning: session)
            continuation = nil
        }
        func fail(_ error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    private final class Model: ObservableObject {
        @Published var configuration: TranslationSession.Configuration?
        var currentSession: TranslationSession?
        var waiters: [Waiter] = []

        func deliver(_ session: TranslationSession) {
            currentSession = session
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume(session) }
        }
    }

    private let model = Model()
    private var hostWindow: NSWindow?

    private init() {}

    @MainActor
    func translate(_ text: String, source: String, target: String) async throws -> String {
        ensureHostInstalled()

        guard let targetLang = Self.localeLanguage(for: target) else {
            throw RuntimeError("系统翻译不支持的目标语言: \(target)")
        }
        let sourceLang = (source == "auto") ? nil : Self.localeLanguage(for: source)

        // 源语言已知时预检语言对可用性；自动检测则跳过（此刻无法确定源语言）。
        if let sourceLang {
            let status = await LanguageAvailability().status(from: sourceLang, to: targetLang)
            if status == .unsupported {
                throw RuntimeError("系统翻译不支持该语言对")
            }
        }

        let config = TranslationSession.Configuration(source: sourceLang, target: targetLang)
        let session = try await session(for: config)
        let response = try await session.translate(text)
        return response.targetText
    }

    @MainActor
    private func session(for config: TranslationSession.Configuration) async throws -> TranslationSession {
        if model.configuration == config, let existing = model.currentSession {
            return existing
        }
        // 改变配置会触发宿主视图的 translationTask 回送新 session。
        model.currentSession = nil
        model.configuration = config
        return try await withCheckedThrowingContinuation { continuation in
            let waiter = Waiter(continuation)
            model.waiters.append(waiter)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if let index = model.waiters.firstIndex(where: { $0 === waiter }) {
                    model.waiters.remove(at: index)
                    waiter.fail(RuntimeError("系统翻译初始化超时，请确认已下载对应语言模型"))
                }
            }
        }
    }

    @MainActor
    private func ensureHostInstalled() {
        guard hostWindow == nil else { return }
        let hosting = NSHostingView(rootView: HostView(model: model))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        hostWindow = window
    }

    private struct HostView: View {
        @ObservedObject var model: Model
        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .translationTask(model.configuration) { session in
                    await MainActor.run { model.deliver(session) }
                }
        }
    }

    /// 本项目语言码 → `Locale.Language`。`auto` 由调用方处理为 nil（自动检测）。
    static func localeLanguage(for code: String) -> Locale.Language? {
        switch code {
        case "zh-CN": return Locale.Language(identifier: "zh-Hans")
        case "en": return Locale.Language(identifier: "en")
        case "ja": return Locale.Language(identifier: "ja")
        case "ko": return Locale.Language(identifier: "ko")
        case "fr": return Locale.Language(identifier: "fr")
        case "de": return Locale.Language(identifier: "de")
        case "ru": return Locale.Language(identifier: "ru")
        case "auto": return nil
        default: return Locale.Language(identifier: code)
        }
    }
}
