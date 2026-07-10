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
        /// 语言模型下载期间为 true：宿主视图从 1×1 透明占位切换为可见的说明面板。
        @Published var isDownloadPresentation = false
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
        var needsModelDownload = false
        if let sourceLang {
            let status = await LanguageAvailability().status(from: sourceLang, to: targetLang)
            switch status {
            case .unsupported:
                throw RuntimeError("系统翻译不支持该语言对")
            case .supported:
                // 语言对受支持但模型尚未下载，需要用户确认下载。
                needsModelDownload = true
            case .installed:
                break
            @unknown default:
                break
            }
        }

        let config = TranslationSession.Configuration(source: sourceLang, target: targetLang)
        let session = try await session(for: config)

        if needsModelDownload {
            // 下载确认是挂在宿主窗口上的系统 sheet；宿主必须可见，
            // 否则弹窗落在屏幕外的 1×1 隐形窗口上，用户永远看不到、只会等到超时。
            presentDownloadHost()
            defer { dismissDownloadHost() }
            do {
                try await session.prepareTranslation()
            } catch {
                throw RuntimeError("语言模型未就绪：\(error.localizedDescription)")
            }
        }

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
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        hostWindow = window
    }

    /// 把隐形宿主临时变为屏幕中央的可见面板，承载语言模型下载确认 sheet。
    @MainActor
    private func presentDownloadHost() {
        guard let window = hostWindow else { return }
        model.isDownloadPresentation = true
        let size = NSSize(width: 380, height: 150)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        window.setFrame(
            NSRect(
                x: screen.midX - size.width / 2,
                y: screen.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        window.hasShadow = true
        window.ignoresMouseEvents = false
        window.level = .floating
        window.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
    }

    /// 下载流程结束后恢复隐形形态；窗口保持存活以继续承载 TranslationSession。
    @MainActor
    private func dismissDownloadHost() {
        guard let window = hostWindow else { return }
        model.isDownloadPresentation = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.setFrame(NSRect(x: -10_000, y: -10_000, width: 1, height: 1), display: false)
        window.orderFrontRegardless()
    }

    private struct HostView: View {
        @ObservedObject var model: Model
        var body: some View {
            Group {
                if model.isDownloadPresentation {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在准备系统翻译语言包…")
                            .font(.system(size: 13, weight: .semibold))
                        Text("如系统弹出下载确认，请点击「下载」。下载完成后会自动继续翻译。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Color.clear
                        .frame(width: 1, height: 1)
                }
            }
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
