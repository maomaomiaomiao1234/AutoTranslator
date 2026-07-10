import Cocoa
import ApplicationServices

/// 辅助功能授权协调器。
///
/// 旧行为是「未授权 → 弹系统提示 → exit(1)，授权后手动重启」；对上架产品这既是审核
/// 阻塞项（应用表现为无法使用），体验也差。新行为：
/// 1. 未授权时应用照常驻留菜单栏——翻译输入、截图翻译、翻译历史均不依赖辅助功能；
/// 2. 弹一次系统授权提示 + 一次应用内引导（含「打开系统设置」按钮）；
/// 3. 后台轮询授权状态，授权到位后回调 `onGranted` 启动划词监听。
///    事件 tap 与 AX 取词在授权后即可创建，无需重启应用。
final class AccessibilityPermissionCoordinator {

    private(set) var isGranted: Bool = AXIsProcessTrusted()
    private var pollTimer: Timer?

    /// 授权到位时回调（主线程）。begin() 时已授权则同步回调一次。
    var onGranted: (() -> Void)?

    func begin() {
        isGranted = AXIsProcessTrusted()
        if isGranted {
            onGranted?()
            return
        }

        promptSystemDialog()
        presentGuidanceAlert()
        startPolling()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    static func openSystemSettings() {
        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        guard let url = URL(string: pane) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 系统级授权提示（把本应用加入辅助功能列表的标准弹窗）。
    private func promptSystemDialog() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func presentGuidanceAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "开启划词翻译需要辅助功能权限"
        alert.informativeText = """
        请在 系统设置 > 隐私与安全性 > 辅助功能 中允许 AutoTranslator。\
        该权限仅用于监听划词手势和读取当前选中的文本。

        授权后划词翻译会自动开始工作，无需重启应用。\
        在此之前，菜单栏中的「翻译输入」「截图翻译」「翻译历史」仍可正常使用。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            Self.openSystemSettings()
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, AXIsProcessTrusted() else { return }
            self.isGranted = true
            self.stop()
            self.onGranted?()
        }
        pollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
