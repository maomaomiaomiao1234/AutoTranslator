import Cocoa
import UserNotifications

/// 系统通知封装。
///
/// 仅在程序被打包成 `.app`（拥有 bundleIdentifier）时才会调用
/// `UNUserNotificationCenter`，否则在裸可执行文件下该 API 会抛出
/// `NSInternalInconsistencyException`。无 bundle 时降级为 stderr 输出。
final class NotificationManager: NSObject {

    static let shared = NotificationManager()

    private enum AuthorizationState {
        case unknown      // 尚未发起请求
        case requesting   // 请求已发出，回调未归
        case granted
        case denied
    }

    private var state: AuthorizationState = .unknown
    /// 授权回调归来前想发的通知。启动早期的通知（如「已改用系统翻译」）
    /// 此前因 authorized 尚为 false 而每次必丢；现在先入队、授权通过后重放。
    private var pendingPosts: [(title: String, body: String)] = []
    private static let maxPendingPosts = 8

    /// 当前进程是否处于一个真正的 .app bundle 中。
    private let isBundled: Bool = {
        guard let id = Bundle.main.bundleIdentifier, !id.isEmpty else { return false }
        // swift build 产物的 bundleURL 通常以 .build/debug/ 结尾，没有 .app 后缀
        return Bundle.main.bundleURL.pathExtension == "app"
    }()

    private override init() {}

    /// 在应用启动后调用，请求横幅通知权限。未打包时静默跳过。
    func requestAuthorization() {
        guard state == .unknown else { return }

        guard isBundled else {
            AppLog.debug("未以 .app 形式运行，已跳过系统通知权限请求")
            state = .denied
            return
        }

        state = .requesting
        // 不设 delegate 的话，应用前台（浮窗为 key）时系统一律不显示横幅。
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppLog.error("通知权限请求失败: \(error)")
            }
            // 回调线程不定；状态与队列都是主线程数据。
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.state = granted ? .granted : .denied
                let queued = self.pendingPosts
                self.pendingPosts = []
                guard granted else { return }
                for post in queued {
                    self.deliver(title: post.title, body: post.body)
                }
            }
        }
    }

    func post(title: String, body: String) {
        AppLog.debug("[通知] \(title) - \(body)")

        guard isBundled else { return }

        switch state {
        case .granted:
            deliver(title: title, body: body)
        case .unknown, .requesting:
            // 授权未决：入队等回调，防启动期通知静默丢失。上限防极端情况下无限堆积。
            if pendingPosts.count < Self.maxPendingPosts {
                pendingPosts.append((title, body))
            }
        case .denied:
            break
        }
    }

    private func deliver(title: String, body: String) {
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
            if let error {
                AppLog.error("投递通知失败: \(error)")
            }
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// 应用处于前台时也以横幅展示（默认行为是前台一律不显示）。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
