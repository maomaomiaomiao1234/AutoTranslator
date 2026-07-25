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

## 代码优化与修复（2026-07-21 全项目审查）

> 审查时单元测试全部通过；以下条目均核对到源码行号（行号对应当日工作区，改动后会漂移）。
> 无前缀的文件路径均相对 `AutoTranslator/Sources/AutoTranslator/`。
> 建议顺序：先做「高优先级」里的一行级止血（collectionBehavior、Timer mode、overlay version bump、流式取消兜底），
> 再做小改动大收益项（hide/show 竞态、Apple 桥接、通知投递），最后是两个中型重构（贴图取色采样、历史库下线主线程）。

### 高优先级 bug（核心体验 / 数据正确性）

- [ ] 浮窗补 `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`。
  - `UI/FloatingWindow.swift:13` BorderlessWindow 未设置（贴图翻译的两个窗口都设了）；全屏 app 里划词看不到浮窗。
- [ ] 修复 hide→show 竞态：渐隐 completion 会把刚重新展示的窗口 orderOut。
  - `UI/FloatingWindow.swift:697-705` completion 无条件 orderOut + 卸载 Esc 监视器；`:502` 起的 wasVisible 分支不重置 alpha、不作废在途动画。连续查词时窗口"闪一下就没了"。
  - 修法：hideGeneration 计数，completion 发现过期直接 return；show() 强制 `alphaValue = 1`。
- [ ] 流式渲染 Timer 改注册到 `.common` runloop mode。
  - `UI/FloatingWindow.swift:609` scheduledTimer 只跑 default mode，打开菜单/拖拽期间译文冻结、关菜单后爆发追帧。
- [ ] 贴图翻译关闭后作废在途任务。
  - `AppController.swift:1594` overlayDidClose 只 cancel 不 bump overlayVersion；`:437-500` translateOverlayBlocks 用非结构化 Task 且不检查取消 → Esc 关闭后剩余块请求照发、还把已放弃的译文写进历史。
  - 止血：close 里 `overlayVersion += 1`；根治：改 withTaskGroup 结构化并发。
- [ ] 贴图取色降采样 + 移出主线程。
  - `Overlay/PatchStyleSampler.swift:185-202` 逐像素收集 + 全量排序，串行在主 actor（`AppController.swift:362-364`）；大选区（约 380 万像素）主线程冻结秒级。
  - 修法：子采样封顶约 1 万样本、中位数改直方图 O(n)、统计放后台（PatchStyle 已 Sendable）。
- [ ] Apple 翻译桥接：waiter 按配置匹配 + 可取消等待。
  - `Translators/AppleTranslationBridge.swift:40-46` deliver 无差别 resume 所有 waiter，并发换语言时可拿到错误语言对的 session，错译按原 key 写入缓存后永久命中；`:106-116` 等待不响应取消，cancel 后干等 8s 超时。
- [ ] 历史导出/导入/搜索移出主线程。
  - `TranslationHistoryStore.swift:236-284` 全量 fetchAll + 渲染 + 写盘在主线程；`HistoryPDFRenderer.swift:41-46` 为拿页数完整排版两遍；收藏无上限，导出 PDF 可彩球数秒。
- [ ] 内存库回退时跳过旧 JSON 迁移。
  - `TranslationHistoryStore.swift:98-103, 331-351` 磁盘库打开失败回退内存库后，仍把 history.json 迁入内存库并改名 → 下次启动旧历史静默消失（数据搁浅在 .migrated-backup）。回退会话应跳过迁移并通知用户本次不持久。
- [ ] 通知：未决期间入队 + 实现 willPresent。
  - `macOS/NotificationManager.swift` post 以 authorized 为门槛，而授权回调晚于 AppDelegate.init 阶段的通知（如"已改用系统翻译"）→ 启动期通知每次必丢；无 UNUserNotificationCenterDelegate，应用前台时横幅一律不显示。

### 语言检测与词典判定

- [ ] 纯汉字日文误判为中文（「東京駅」「経済」→ 目标被改成英文）。
  - `LanguageHeuristics.swift:24-39` 只看"含汉字且无假名"；建议 NLLanguageRecognizer（constraints 限 zh/ja）对纯汉字文本仲裁。
  - 同族：含单个汉字的英文句整句判中文（加 Han 占比阈值）；片假名中点「・」U+30FB 落在假名区段，「斯蒂芬・金」被判日文（假名检测排除标点/延长符）。
- [ ] 无空格假名整句会进词典模式（「よろしくおねがいします」被当单词 define）。
  - `LanguageHeuristics.swift:57-60`；含假名文本应与中文同样要求命中系统词典才进词典模式。

### 性能与健壮性

- [ ] LLM SSE 解析移出主线程。
  - 工程开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，`Translators/LLMTranslator.swift:218` 的 Task 隐式 MainActor，每个 token 的 JSON 解析都在主线程；标 nonisolated 或 Task.detached。
- [ ] 流式取消兜底，防半截译文入缓存/历史。
  - 消费端 `AppController.swift:1201-1205` 循环结束后补 `try Task.checkCancellation()`；producer 端 `LLMTranslator.swift:259` 的 `catch CancellationError { finish() }` 改 `finish(throwing:)`。现状 stop() 路径可把截断译文写进历史。
- [ ] LLM 流解析三处小修：`finish_reason == "length"` 截断不应入缓存（`LLMTranslator.swift:244-247`）；流中 `{"error":…}` 行不应静默吞（`:240-243`）；`data:` 前缀容忍无空格变体（`:235`）。
- [ ] 非流式 LLM 请求超时独立配置：30s 闲置超时下长文本必假死，贴图翻译正在用非流式路径（`LLMTranslator.swift:20`）。
- [ ] Google 长度护栏按 UTF-8 字节算：1800 汉字 percent-encode 后约 16KB URL 仍被拒（`Translators/GoogleTranslator.swift:21-25`），或改 POST。
- [ ] 历史 record 减少主线程 SQL：预查 SELECT + UPSERT 合并为 `RETURNING`、trim 改阈值触发、历史窗口未激活时跳过 3×COUNT（`TranslationHistoryStore.swift:160-199, 301-329`）；高频语句 prepared statement 复用（`HistoryDatabase.swift:416` 现每条现场 prepare，导入万条即万次解析同一句）。
- [ ] 历史搜索加 200ms 防抖（`UI/TranslationHistoryView.swift:53` 每键 4 条查询）；LIKE 全表扫描远期可上 FTS5 或物化别名列。
- [ ] 取词合并重复 AX 往返：`AppController` 的 isFocusedElementTextInput 与 TextSelector 各取一次 focused element，慢 app 下各挡 0.2s；合并成一次取回复用。
- [ ] 贴图分组与坐标三处修正：`Overlay/TextBlockGrouper.swift:15-23` 只与当前块最后一行链式比较，多栏被拆成单行碎块（改两两建边 + 并查集）；`:61-68` readingOrder 容差比较违反严格弱序（排序结果未定义）；`Overlay/PatchStyleSampler.swift:134-146` `CGContext(data: &pixels)` 悬垂指针 UB（包进 withUnsafeMutableBytes）。
- [ ] 框选 clamp 到屏幕边界（`Overlay/RegionSelectionController.swift:150` mouseDragged 不夹取），防 capture 宽高比与选区不一致导致贴图整体拉伸；scale 分别按 x/y 计算做防御。
- [ ] ProcessRunner 超时 SIGTERM 后 2-3s 升级 SIGKILL（`ProcessRunner.swift:183-201`），防 OCR 子进程卡死每次滞留 3 个 GCD 线程。
- [ ] 消除 setenv 与后台读 environ 的并发 UB：服务直接从 ConfigStore 内存态取配置（`macOS/ConfigStore.swift:78-86` 写 vs `SpeechService.swift:448-563` nonisolated 读）。
- [ ] TTS capturedChunks 超过 8MB 缓存上限即停止捕获（`SpeechService.swift:133-146`），防长文本播报峰值内存上百 MB。
- [ ] OCR 空图最坏 8-12 轮 accurate 识别：首轮用合并语言列表一次识别，空结果再兜底一轮（`OCRService.swift:397-415, 264-308`）。

### 取词改动（useSwift 工作区）完善

- [ ] `.full` 策略（剪贴板回退关闭时）也加 deadline（如 2s）：`TextSelector.swift:135` 只给 fastLocal 设了 0.18s 预算，慢 app 深搜仍可数十秒并卡住 gate actor 队列。
- [ ] 实测剪贴板恢复路径：`TextSelector.swift:509-517` declareTypes 后 writeObjects 会产生一个声明 .string 但无数据的 item 0，部分读取方可能取到空剪贴板；必要时改 writeObjects 后逐 item 补 transient 标记。
- [ ] 合并两个同形 gate actor（SelectionFocusLookupGate / AccessibilityLookupGate）为泛型 SerialGate；注释说明"阻塞式 AX 同步调用占用协作池线程"的权衡。

### 工程杂项

- [ ] 删除 `verify-tmp/`（文件头自注"验证后删除"）与根目录 `default.profraw`。
- [ ] 修构建警告：Info.plist 不应出现在 Copy Bundle Resources。
- [ ] 日志换 os.Logger：现走 stderr，发布版零诊断能力（已核实现状无 Key/用户文本落日志）。
- [ ] 热键健壮性：注册失败（快捷键被占）暴露状态并可重试（`GlobalHotKeyManager.swift:40-44`）；未授权期间 ⌃⌥E 不应可翻转暂停态，onGranted 应尊重暂停态（`main.swift:123-158`）。
- [ ] 偏好保存不再把同一 Key 写进 deepseek/llm/dashscope 三槽互相冲掉（`macOS/PreferencesWindowController.swift:192-200`）；状态栏「大模型 (DeepSeek)」硬编码改随配置（`macOS/StatusBarController.swift:28`）。
- [ ] 偏好/历史窗口惰性创建（现启动即建，`main.swift:105-106`）；showAndFocus 双重重建 rootView（`macOS/PreferencesWindowController.swift:54-69`）；两窗口补 frameAutosaveName。
- [ ] 浮窗为 key 时 Esc 无条件关窗（现要求鼠标悬停在窗内，纯键盘关不掉，`UI/FloatingWindow.swift:1192-1205`）；标准模式约 12 个图标按钮补 accessibilityLabel（极简模式已有，不一致）。
- [ ] 词典格式化正则 static 预编译（现每次调用现场编译约 8 个，`DictionaryDefinitionFormatter.swift:207-211`）；流式非 done 态跳过全文解析与测量缓存（`UI/FloatingWindow.swift:911-918`）。
- [ ] 贴图 finishFailed 死代码二选一：接回（截屏/OCR 失败保留窗口可重试）或删除（`Overlay/OverlayTranslationController.swift:198`）；「浮窗查看」直接复用已有译文，不重新翻译（`AppController.swift:1564-1570`）。
- [ ] 主题按明暗取值处改用 `@Environment(\.colorScheme)`，统一后删除 appearanceVersion 强刷机制（偏好/历史窗口开着切主题有残留旧值，如阴影透明度）。

### 测试补充（在上文「补充自动化测试」之外）

- [ ] DictionaryDefinitionFormatter（当前零测试）：pipe 头解析、圈号分行、PHRASAL VERBS 分节、"U. S. A." 误断行。
- [ ] SSE 解析抽成纯函数再测：中途 [DONE]、malformed chunk 跳过、finish_reason=length/stop、无完成标记即报中断（防缓存污染的核心逻辑，最值得回归保护）。
- [ ] translationCacheKey / dictionaryWord(from:) 边界用例（后端/语言/模式区分；标点修剪、64 字上限、纯数字拒绝）。
- [ ] LanguageHeuristics 边界：纯汉字日文、单汉字英文句、U+30FB 中点、半角片假名（固化上面两条修复）。
- [ ] 贴图 pinGeometry（零覆盖，极窄选区控制条溢出）与多行×多栏分组用例（会立刻暴露链式比较缺陷）。
