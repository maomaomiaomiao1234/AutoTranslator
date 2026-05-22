import Cocoa
import UserNotifications

/// 系统通知封装。
///
/// 仅在程序被打包成 `.app`（拥有 bundleIdentifier）时才会调用
/// `UNUserNotificationCenter`，否则在裸可执行文件下该 API 会抛出
/// `NSInternalInconsistencyException`。无 bundle 时降级为 stderr 输出。
final class NotificationManager {

    static let shared = NotificationManager()

    private var authorized = false
    private var requested = false

    /// 当前进程是否处于一个真正的 .app bundle 中。
    private let isBundled: Bool = {
        guard let id = Bundle.main.bundleIdentifier, !id.isEmpty else { return false }
        // swift build 产物的 bundleURL 通常以 .build/debug/ 结尾，没有 .app 后缀
        return Bundle.main.bundleURL.pathExtension == "app"
    }()

    private init() {}

    /// 在应用启动后调用，请求横幅通知权限。未打包时静默跳过。
    func requestAuthorization() {
        guard !requested else { return }
        requested = true

        guard isBundled else {
            fputs("[AutoTranslator] 未以 .app 形式运行，已跳过系统通知权限请求（仅日志输出）。\n", stderr)
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            self?.authorized = granted
            if let error = error {
                fputs("[AutoTranslator] 通知权限请求失败: \(error)\n", stderr)
            }
        }
    }

    func post(title: String, body: String) {
        // 始终在 stderr 留一份，方便日志调试
        fputs("[AutoTranslator] [通知] \(title) - \(body)\n", stderr)

        guard isBundled else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                fputs("[AutoTranslator] 投递通知失败: \(error)\n", stderr)
            }
        }
    }
}
