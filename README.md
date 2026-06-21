# AutoTranslator

一个常驻 macOS 菜单栏的划词翻译工具。选中文字即弹出浮窗翻译，另支持截图 OCR 翻译、单词词典释义和语音朗读。翻译后端可在**大模型**（OpenAI 兼容接口，流式输出）与 **Google 翻译**之间切换。

- 平台：macOS 13.0+
- 语言：Swift 5（AppKit + SwiftUI 混合）
- 形态：菜单栏 App（`LSUIElement`，无 Dock 图标）

## 功能特性

- **划词翻译** —— 在任意应用中用鼠标拖拽选中文字，松开后自动在浮窗中显示译文。优先通过 Accessibility API 读取选区，失败时回退到模拟 `⌘C`（会自动备份并还原剪贴板）。
- **截图翻译 (OCR)** —— 框选屏幕任意区域，用 Vision 框架识别其中文字后翻译。OCR 在独立子进程中运行，避免拉高主进程内存。
- **单词词典** —— 选中单个单词时，给出词典式释义（词性 / 释义 / 例句）而非整句直译；优先查询系统词典，未命中再走大模型。
- **语音朗读 (TTS)** —— 流式合成并播放发音，可设置单词释义完成后自动朗读。基于 DashScope CosyVoice。
- **流式输出** —— 大模型后端逐字显示译文，浮窗高度随内容自适应增长。
- **结果缓存** —— 对相同文本/语言/后端的请求做 LRU 缓存，重复划词不重复请求。
- **翻译历史** —— 成功结果自动保存在本地，支持即时搜索、收藏、复制、单条删除及清空非收藏记录；重复翻译会合并并更新到最前。
- **外观主题** —— 跟随系统 / 浅色 / 深色。
- **极简浮窗** —— 可切换为只显示译文、隐藏原文与工具栏的紧凑窗口。

支持的语言：自动检测（仅源语言）、中文简体、英语、日语、韩语、法语、德语、俄语。

## 环境要求

- macOS 13.0 或更高版本
- Xcode 15+（含 macOS SDK）
- 大模型后端需要一个 OpenAI 兼容服务的 API Key（默认面向 DeepSeek / 阿里云 DashScope）；不配置则自动回退到免费的 Google 翻译

## 构建与运行

本仓库只纳入源码（`.xcodeproj` 已被 `.gitignore` 忽略，见下方说明）。在已有 Xcode 工程的情况下：

```bash
# 用 Xcode 打开并运行
open AutoTranslator.xcodeproj
# 选择 AutoTranslator scheme，按 ⌘R 运行

# 或用命令行构建
xcodebuild -project AutoTranslator.xcodeproj -scheme AutoTranslator -configuration Release build
```

首次运行需在「系统设置 → 隐私与安全性」中授予权限（见[权限说明](#权限说明)），然后从菜单栏的「译」图标进入功能。

> **关于从零克隆构建**
> `.gitignore` 忽略了 `*.xcodeproj/`，因此 `git clone` 得到的只有源码，没有可直接打开的工程文件。仓库中纳入版本控制的内容为：
> - `AutoTranslator/Sources/AutoTranslator/`：全部 Swift 源码
> - `AutoTranslator/Resources/Info.plist`、`AutoTranslator/Assets.xcassets/`：资源与图标
> - `AutoTranslatorTests/`、`AutoTranslatorUITests/`：测试目标
>
> 若从纯净克隆开始，需要新建一个 macOS App 工程（或自行添加 `Package.swift`）并把上述源码加入目标。重建工程时的关键设置：
> - Deployment Target：macOS 13.0
> - Bundle Identifier：`whang1234.AutoTranslator`
> - `Info.plist` 中需保留 `LSUIElement = true` 以及三条权限用途说明（辅助功能 / Apple Events / 屏幕录制）

## 权限说明

| 权限 | 用途 |
| --- | --- |
| 辅助功能（Accessibility） | 监听全局鼠标事件以识别划词手势，并读取选中文本 |
| 屏幕录制（Screen Recording） | 截图翻译时截取框选区域 |
| Apple Events | 划词回退方案中模拟 `⌘C` 复制选区 |

辅助功能权限是划词翻译的前提，缺失时 App 会在启动时退出并提示授权。

## 配置

最常用的方式是从菜单栏 **偏好设置…（⌘,）** 进行可视化配置，涵盖：翻译后端、API Key、模型、Base URL、语音 Key/模型/音色/Endpoint、自动朗读开关、源/目标语言、外观主题、极简浮窗开关。

所有配置持久化在：

```
~/Library/Application Support/AutoTranslator/config.json
```

翻译历史独立保存在 `~/Library/Application Support/AutoTranslator/history.json`。默认最多保留 500 条非收藏记录，收藏项不会被自动清理。

可从“翻译历史”窗口右上角导出全部历史或仅导出收藏；导出文件为 JSON，可在另一台设备通过“导入”恢复。导入不会清空本地记录：相同原文、语言、后端和记录类型会合并为较新的内容，收藏状态会保留。

配置项也可通过**环境变量**提供（启动时读取，不覆盖已存在的同名变量；JSON 文件中的键名与环境变量名一致）：

| 键 | 说明 | 默认值 |
| --- | --- | --- |
| `TRANSLATOR_BACKEND` | 翻译后端：`llm` 或 `google` | `llm`（无 Key 时回退 `google`） |
| `DEEPSEEK_API_KEY` / `LLM_API_KEY` / `DASHSCOPE_API_KEY` | 大模型 API Key（任填其一） | 无 |
| `LLM_MODEL` | 大模型名称 | `deepseek-v3.2` |
| `LLM_BASE_URL` | OpenAI 兼容接口地址（填到 `/v1`，路径自动拼接） | `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| `TTS_API_KEY` | 语音合成 Key（留空则沿用 DashScope Key） | 无 |
| `TTS_AUTO_PLAY` | 单词释义后自动朗读：`1`/`true`/`yes`/`on` | 关闭 |
| `TTS_MODEL` | 语音模型 | `cosyvoice-v3-flash` |
| `TTS_VOICE` | 音色 | `longanyang` |
| `TTS_BASE_URL` | 语音合成 Endpoint | DashScope SpeechSynthesizer |
| `SRC_LANG` | 源语言代码 | `auto` |
| `DEST_LANG` | 目标语言代码 | `zh-CN` |
| `THEME` | 外观：`system` / `light` / `dark` | `system` |
| `FLOATING_WINDOW_MODE` | 浮窗模式：`standard` / `minimal` | `standard` |

## 使用方法

启动后 App 以「译」图标常驻菜单栏，点击图标可：

- 切换翻译后端（大模型 / 谷歌翻译）
- 发起**截图翻译**
- 打开**翻译历史**，搜索、收藏或管理已完成的结果
- 暂停 / 恢复划词监听（全局快捷键 **⌥E**）
- 切换主题外观
- 打开偏好设置（**⌘,**）、退出

日常用法：

- **划词**：在任意应用中拖拽选中文字，松手后浮窗自动出现译文；选中单个单词时显示词典释义。
- **截图**：菜单栏选择「截图翻译」，框选包含文字的区域。
- **收藏**：翻译完成后点击译文卡片底部的星标；也可在历史窗口中收藏或取消收藏。
- **朗读**：在浮窗中点击发音按钮，或开启自动朗读让单词释义完成后自动发音。

## 项目结构

```
AutoTranslator/Sources/AutoTranslator/
├── main.swift                    入口；权限检查、菜单与热键装配；兼任 OCR 子进程
├── AppController.swift           核心调度器：划词→取文本→翻译分发、缓存、模式判定
├── Translators/
│   ├── TranslatorProtocol.swift  翻译器协议（含流式默认实现）
│   ├── GoogleTranslator.swift    Google 免费接口（非流式）
│   └── LLMTranslator.swift       OpenAI 兼容接口（流式翻译 + 词典）
├── MouseMonitor.swift            CGEventTap 监听鼠标，判定选择手势
├── TextSelector.swift            Accessibility 读取选区 + 剪贴板回退
├── OCRService.swift              Vision OCR（子进程隔离）
├── ScreenCaptureService.swift    交互式框选截图
├── SpeechService.swift           流式 TTS 播放 + 音频缓存
├── SystemDictionary.swift        系统词典查询
├── Languages.swift / Theme.swift 语言与主题枚举
├── LRUCache.swift / Logger.swift / Errors.swift
├── TranslationHistoryStore.swift  历史记录模型、去重、容量控制与 JSON 持久化
├── UI/
│   ├── FloatingWindow.swift      浮窗 NSWindow：定位、自适应尺寸、缩放
│   ├── FloatingWindowView.swift  浮窗 SwiftUI 内容（标准 / 极简两种布局）
│   ├── FloatingWindowMode.swift  浮窗模式枚举
│   ├── PreferencesView.swift     偏好设置界面
│   ├── TranslationHistoryView.swift  历史搜索、收藏与详情界面
│   ├── DesignSystem.swift / SwiftUIDesignSystem.swift  颜色与尺寸常量
└── macOS/
    ├── StatusBarController.swift     菜单栏图标与下拉菜单
    ├── PreferencesWindowController.swift  偏好设置窗口控制器
    ├── HistoryWindowController.swift      翻译历史窗口控制器
    ├── ConfigStore.swift             config.json 读写
    └── NotificationManager.swift     系统通知
```

### 工作原理（简述）

1. `MouseMonitor` 通过 `CGEventTap` 监听左键按下/拖拽/抬起，依据拖拽距离与点击次数判断是否为一次「选择手势」。
2. 命中后 `AppController` 调用 `TextSelector` 获取选区文本（Accessibility 优先，失败回退剪贴板）。
3. 根据文本判断是「整句翻译」还是「单词词典」，分发到对应翻译器；命中缓存或系统词典则直接返回。
4. 结果（流式或一次性）回传到 `FloatingWindow` 显示，窗口高度随内容自适应。

## 已知限制

- 仅适配 macOS（依赖 AppKit、Vision、Accessibility、Carbon 热键等系统框架）。
- 划词依赖目标应用对 Accessibility 的支持；个别应用只能走剪贴板回退。
- 大模型与语音功能默认面向 DashScope / DeepSeek，使用其它服务商需自行配置 Base URL、模型与音色。
- `.xcodeproj` 未纳入版本控制（见构建说明）。

## 许可证

仓库尚未声明开源许可证。如需开放使用或分发，请补充 `LICENSE` 文件。
