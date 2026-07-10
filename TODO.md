# TODO

## App Store 上架准备

### 必须解决

- [ ] 开启 App Sandbox，并重新验证核心能力。
  - 当前工程 `ENABLE_APP_SANDBOX = NO`，Mac App Store 需要 sandbox。
  - 补齐必要 entitlements：app sandbox、`com.apple.security.network.client`（当前缺失，所有翻译/TTS 请求会被沙盒拦截）、用户选择文件读写（历史导入导出）等。
  - **确定失效、需要重写**（不是验证）：
    - `/usr/sbin/screencapture` 子进程截图 → 改用 ScreenCaptureKit（macOS 14+ 可用 `SCContentSharingPicker`）。
    - 复用自身可执行文件的 OCR 子进程 → 改为 XPC Service，或退回进程内 Vision OCR。
  - 需授权后实测：沙盒 + 用户手动授予辅助功能下的 AX 取词、CGEventTap 全局鼠标监听、模拟 `Cmd+C`（Bob/PopClip 类应用有先例，但须逐项验证并准备 Review Notes）。
  - 其余验证：Keychain、历史文件读写（容器内路径迁移）、历史导入导出。

- [x] 清理 entitlements。
  - ~~当前存在 `group.com.whang1234.device-moments`~~ 已删除该 App Group 及配套的
    `TranslationActivityRecorder`（划词活动写入外部共享容器 + 分布式通知）整条代码路径。

- [ ] 增加隐私政策和应用内隐私入口。
  - 说明会读取用户选中文本、截图 OCR 文本、手动输入文本。
  - 说明哪些数据仅本地处理，哪些会发送到第三方翻译/TTS 服务。
  - 说明 API Key 存储在 Keychain，历史记录保存在本地。
  - 说明数据保留、删除、撤回授权方式。

- [ ] 增加首次启动 onboarding/权限说明。
  - 辅助功能：用于监听划词和读取选中文本。
  - 屏幕录制：仅用于用户主动框选截图 OCR。
  - 通知：用于显示状态和错误提示。
  - 第三方 AI/TTS：翻译或发音时可能发送文本到配置的服务商。

- [x] 重新设计剪贴板回退授权。
  - 已增加独立开关（偏好设置「取词方式 > 剪贴板回退」，配置键 `CLIPBOARD_FALLBACK`，默认开启）。
  - 开关文案说明了模拟 ⌘C 与恢复剪贴板的行为；关闭后完全不触碰剪贴板。
  - 待办：接入首次启动 onboarding 时再评估默认值是否改为关闭。

- [ ] 处理 Google 翻译非官方接口风险。
  - 已完成：移除所有「静默回退到 Google」路径——无 Key 时 macOS 15+ 改用 Apple 系统翻译并通知，
    更早系统展示配置引导；词典模式不再绕过用户选择的后端；仅用户显式选择 Google 时才使用该接口。
  - 待定：上架版是否彻底移除该后端、隐藏为高级选项，或改为官方授权服务。
  - 默认后端建议改为 Apple 系统翻译或用户自带 OpenAI-compatible API。

### 隐私与数据控制

- [ ] 增加历史记录隐私选项。
  - 开关：是否自动保存翻译历史。
  - 操作：一键清空全部历史。
  - 策略：可选自动清理周期或最大保留量说明。
  - UI 中展示本地历史文件位置和删除方式。

- [ ] 审核 App Store Privacy Nutrition Label。
  - 按实际行为填写用户内容、搜索/输入内容、诊断、第三方服务处理等项目。
  - 如果文本只为实时请求传输且第三方不保留，仍需要在隐私政策中说明处理链路。

- [ ] 梳理第三方服务条款。
  - LLM Base URL 默认服务、DashScope TTS、Google 翻译接口都需要明确服务商和数据处理责任。
  - App Review Notes 中说明用户可自带 API Key，以及文本发送的触发条件。

### 交互与产品化

- [x] 改善首次未授权体验。
  - 已完成：未授权不再退出。应用驻留菜单栏（翻译输入/截图/历史可用），弹系统提示 + 应用内引导
    （含「打开系统设置」按钮），后台轮询授权状态，授权后自动启动划词，无需重启。
  - 菜单栏显示「等待辅助功能授权」状态并提供「打开辅助功能设置…」入口。

- [ ] 增加权限诊断页。
  - 显示辅助功能、屏幕录制、通知、网络、API Key、Apple 翻译可用性等状态。

- [ ] 增加帮助/支持入口。
  - 包含支持 URL、隐私政策、问题反馈、权限说明、数据删除说明。

- [x] 调整权限用途描述文案。
  - 已移除 `NSAppleEventsUsageDescription`（应用使用 CGEvent 而非 Apple Events，该键无用且误导）。
  - `NSScreenCaptureUsageDescription` 已改为“仅在主动框选截图 OCR 时截取所选范围，不后台截屏”。
  - 辅助功能描述已补充“仅在无法直接读取选区时才模拟 ⌘C”。

- [ ] 梳理菜单栏 App 的可发现性。
  - 确认无 Dock 图标时，偏好设置、历史、退出、暂停监听、帮助都能从菜单栏稳定进入。

### 工程与发布

- [ ] 将 `AutoTranslator.xcodeproj` 纳入版本控制，或提供可重复生成工程的方式。

- [x] 统一版本号。
  - `Info.plist` 已改用 `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` 占位符，随工程设置走。

- [ ] 替换开发者 Team、Bundle ID 和签名配置。
  - 移除当前个人 Team ID，改为发布账号配置。

- [ ] 准备 App Store Connect 元数据。
  - 应用名、描述、关键词、分类、截图、隐私政策 URL、支持 URL、审核说明、年龄分级。

- [ ] 准备 Review Notes。
  - 说明菜单栏入口。
  - 说明辅助功能、屏幕录制、剪贴板回退的具体用途。
  - 说明第三方 API Key 配置方式和可测试路径。

- [ ] 检查开源许可证和第三方依赖授权。
  - 当前仓库尚无 `LICENSE`。
  - 上架前确认图标、资源、代码、接口使用授权。

### 测试与质量

- [ ] 增加 sandbox 环境下的手工验收清单。
  - 首次启动授权。
  - 划词翻译。
  - AX 失败后的剪贴板回退。
  - 截图 OCR。
  - Apple 系统翻译。
  - LLM 流式翻译。
  - TTS 发音和音频缓存。
  - 历史保存、搜索、收藏、清空、导入、导出。

- [ ] 补充自动化测试。
  - 翻译缓存 key。
  - 语音缓存 key 和容量行为。
  - 历史开关、清空、导入导出。
  - 配置迁移和 Keychain 存储。
  - 网络错误、401/403、超时、无 API Key 的用户提示。

- [ ] 补充 UI 测试。
  - 当前 UI 测试基本是模板，需要覆盖菜单栏入口、偏好设置、历史窗口、手动输入、错误态。

- [ ] 做发布构建验证。
  - Release 构建。
  - App Store 签名。
  - Sandbox 开启后的本机完整验收。
  - TestFlight 审核前 smoke test。
