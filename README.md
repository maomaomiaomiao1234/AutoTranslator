# AutoTranslator

AutoTranslator 是一款常驻 macOS 菜单栏的划词翻译工具。在任意应用中选中文字，即可通过浮窗查看译文；也支持手动输入、截图 OCR、单词释义、语音朗读和翻译历史。

- macOS 13.0+
- Swift 5 / AppKit / SwiftUI
- 菜单栏应用，无 Dock 图标

## 功能

- **划词翻译**：鼠标选中文字后自动弹出翻译浮窗。优先通过 Accessibility API 获取选区，失败时临时模拟 `⌘C`，并在读取后恢复原剪贴板内容。
- **手动输入**：从菜单栏打开「翻译输入…」，直接输入或修改原文后提交翻译。
- **截图翻译**：框选屏幕区域，使用 Vision OCR 识别文字并翻译。OCR 在独立子进程中执行，降低主进程的内存压力。
- **单词词典**：选中单个单词时优先查询 macOS 系统词典；未命中时由当前后端生成简明释义。
- **三种翻译后端**：支持 OpenAI 兼容的大模型接口、Google 翻译，以及 macOS 15+ 的 Apple 系统翻译。
- **流式输出**：大模型后端支持流式返回，浮窗随内容自动调整高度。
- **语音朗读**：通过 DashScope CosyVoice 朗读原文，可配置单词释义完成后自动播放。
- **翻译历史**：本地保存结果，支持搜索、收藏、复制、删除以及 JSON 导入/导出。
- **结果缓存**：使用 LRU 缓存复用相同文本、语言和后端的翻译结果。
- **浮窗定制**：支持固定窗口、切换语言、交换翻译方向、复制内容、重新翻译、标准/极简模式，以及跟随系统/浅色/深色主题。
- **快捷控制**：使用全局快捷键 `⌥E` 暂停或恢复划词监听。

当前支持自动检测源语言，以及中文简体、英语、日语、韩语、法语、德语和俄语。目标语言不包含「自动检测」。

## 翻译后端

| 后端 | 系统要求 | API Key | 特点 |
| --- | --- | --- | --- |
| 大模型 | macOS 13+ | 需要 | OpenAI 兼容 `/chat/completions` 接口，支持流式翻译和词典释义 |
| Google 翻译 | macOS 13+ | 不需要 | 使用 Google Translate Web 接口，非流式，需要网络 |
| Apple 系统翻译 | macOS 15+ | 不需要 | 使用系统 Translation 框架；对应语言模型就绪后可离线使用 |

默认选择大模型后端。未配置大模型 API Key 时，应用会自动回退到 Google 翻译。

> Google 后端使用的是非官方公开 Web 接口，可能受到网络环境、访问频率或服务变更影响，不适合依赖稳定 SLA 的生产场景。

## 环境要求

- macOS 13.0 或更高版本
- 完整安装的 Xcode，且包含 macOS 15 或更高版本 SDK（当前工作区已使用 Xcode 27 beta 验证）
- 使用大模型后端时，需要兼容 OpenAI Chat Completions API 的服务
- 使用语音朗读时，需要 DashScope CosyVoice API Key

## 构建与运行

### 使用 Xcode

```bash
open AutoTranslator.xcodeproj
```

选择 `AutoTranslator` scheme 后按 `⌘R` 运行。若签名失败，请在 Target 的 **Signing & Capabilities** 中选择自己的开发团队，或清空仓库作者的 Team 设置。

### 生成本地应用

仓库提供了本地构建脚本。它会执行 Release 构建、对产物进行 ad-hoc 签名，并输出到 `dist/AutoTranslator-local.app`：

```bash
sh scripts/build-local.sh
open dist/AutoTranslator-local.app
```

脚本优先使用 `/Applications/Xcode-beta.app`，其次使用 `/Applications/Xcode.app`。也可以显式指定 Xcode：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  sh scripts/build-local.sh
```

### 运行测试

```bash
xcodebuild test \
  -project AutoTranslator.xcodeproj \
  -scheme AutoTranslator \
  -destination 'platform=macOS'
```

> **当前仓库限制**：`.gitignore` 中包含 `*.xcodeproj/`，因此工程文件虽然存在于当前本地工作区，但没有纳入 Git。纯净克隆只会得到源码，无法直接执行上述构建命令。若要发布仓库，应先将 `AutoTranslator.xcodeproj` 纳入版本控制；否则需要新建 macOS App 工程并加入 `AutoTranslator/`、`AutoTranslatorTests/` 和 `AutoTranslatorUITests/`。

## 首次运行

1. 启动 AutoTranslator。应用会显示在菜单栏，不会出现在 Dock 中。
2. 按系统提示授予「辅助功能」权限；授权后重新启动应用。
3. 如需截图翻译，再授予「屏幕与系统音频录制」权限。
4. 从菜单栏打开「偏好设置…」，选择翻译后端和语言。使用大模型时请填写 API Key、模型和 Base URL。
5. 在其他应用中拖动选择文字，松开鼠标后即可看到翻译浮窗。

### 权限用途

| 权限 | 用途 |
| --- | --- |
| 辅助功能 | 监听全局鼠标事件、读取选中文字，并在必要时模拟复制快捷键 |
| 屏幕与系统音频录制 | 截取用户框选的屏幕区域，用于 OCR 翻译 |
| 通知 | 显示后端切换、暂停监听和配置保存等状态 |

辅助功能权限是划词监听的前提。未授权时，应用会提示授权并退出；完成授权后需再次启动。

## 使用方法

点击菜单栏中的翻译图标可以：

- 切换大模型、Google 或 Apple 系统翻译后端
- 打开「翻译输入…」手动提交文本
- 发起截图翻译
- 打开翻译历史
- 暂停或恢复划词监听
- 切换主题并打开偏好设置

浮窗中可以修改原文、切换语言、交换翻译方向、切换后端、重新翻译、朗读、复制、收藏、固定或关闭窗口。单个单词会自动进入词典模式，其他文本按普通翻译处理。

## 配置

推荐通过菜单栏的「偏好设置…」管理配置。非敏感配置保存在：

```text
~/Library/Application Support/AutoTranslator/config.json
```

API Key 不会以明文写入该文件，而是合并保存在 macOS Keychain 的 `AutoTranslatorSecrets` 条目中。翻译历史单独保存在：

```text
~/Library/Application Support/AutoTranslator/history.json
```

历史默认保留最近 500 条非收藏记录；收藏记录不受此上限影响。导入历史时会按照原文、语言、后端和记录类型合并重复项，并保留收藏状态。

### 环境变量

配置也可以通过环境变量传入。进程环境变量的优先级高于本地配置：

| 变量 | 说明 | 默认值 |
| --- | --- | --- |
| `TRANSLATOR_BACKEND` | `llm`、`google` 或 `apple` | `llm`；无 Key 时回退到 `google` |
| `DEEPSEEK_API_KEY` | 大模型 API Key | 无 |
| `LLM_API_KEY` | 通用大模型 API Key，作为上一项的候选 | 无 |
| `DASHSCOPE_API_KEY` | DashScope Key，也可作为大模型和 TTS 的候选 | 无 |
| `LLM_MODEL` | OpenAI 兼容接口使用的模型 | `deepseek-v4-flash` |
| `LLM_BASE_URL` | API 根地址，填写到 `/v1` | `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| `TTS_API_KEY` | CosyVoice Key；留空时依次尝试复用 DashScope、大模型 Key | 无 |
| `TTS_AUTO_PLAY` | `1`、`true`、`yes` 或 `on` 时自动朗读单词 | 关闭 |
| `TTS_MODEL` | 语音模型 | `cosyvoice-v3-flash` |
| `TTS_VOICE` | 语音音色 | `longanyang` |
| `TTS_BASE_URL` | DashScope SpeechSynthesizer Endpoint | 内置 Endpoint |
| `SRC_LANG` | 源语言代码 | `auto` |
| `DEST_LANG` | 目标语言代码 | `zh-CN` |
| `THEME` | `system`、`light` 或 `dark` | `system` |
| `FLOATING_WINDOW_MODE` | `standard` 或 `minimal` | `standard` |

如果要为官方 DeepSeek 或其他兼容服务配置后端，请同时修改 `LLM_BASE_URL`、`LLM_MODEL` 和对应 API Key；应用会在 Base URL 后拼接 `/chat/completions`。被 TTS 复用的 Key 仍需具备 DashScope CosyVoice 的访问权限。

## 项目结构

```text
AutoTranslator/
├── Sources/AutoTranslator/
│   ├── main.swift                       应用入口、权限检查和 OCR 子进程入口
│   ├── AppController.swift              划词、翻译、缓存、历史与语音的核心调度
│   ├── MouseMonitor.swift               全局鼠标选择手势监听
│   ├── TextSelector.swift               Accessibility 取词与剪贴板回退
│   ├── ScreenCaptureService.swift       交互式区域截图
│   ├── OCRService.swift                 Vision OCR 与子进程调用
│   ├── SpeechService.swift              CosyVoice 合成、播放与音频缓存
│   ├── TranslationHistoryStore.swift    历史持久化、去重和导入导出
│   ├── Translators/                     LLM、Google 与 Apple 翻译后端
│   ├── UI/                              翻译浮窗、偏好设置和历史界面
│   └── macOS/                           菜单栏、Keychain、配置与窗口控制器
├── Assets.xcassets/                     应用图标与颜色资源
└── Resources/Info.plist                 应用信息与权限用途说明

AutoTranslatorTests/                     单元测试
AutoTranslatorUITests/                   UI 测试
scripts/build-local.sh                   本地 Release 构建与 ad-hoc 签名脚本
```

## 工作流程

1. `MouseMonitor` 监听鼠标按下、拖动和抬起，判断是否形成文字选择手势。
2. `TextSelector` 优先通过 Accessibility 获取选区，失败时使用剪贴板回退。
3. `AppController` 判断请求属于普通翻译还是单词词典，并检查系统词典和 LRU 缓存。
4. 请求被发送到当前翻译后端，结果实时或一次性显示在 `FloatingWindow` 中。
5. 成功结果写入本地历史；如启用自动朗读，词典结果完成后触发 TTS。

## 已知限制

- 仅支持 macOS，依赖 AppKit、Accessibility、Vision、Carbon 和 Translation 等系统框架。
- 某些应用无法通过 Accessibility 直接提供选区，只能使用剪贴板回退；受保护内容可能完全无法读取。
- Apple 系统翻译仅在 macOS 15+ 显示，且需要系统支持对应语言对及语言模型。
- Google 翻译后端依赖非官方 Web 接口；大模型与 TTS 的可用性取决于服务商、网络和账户额度。
- 当前 Git 配置未跟踪 `.xcodeproj`，纯净克隆不能直接构建。

## 许可证

当前仓库尚未包含开源许可证。在添加 `LICENSE` 前，默认保留所有权利。
