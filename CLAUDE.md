# CLAUDE.md

此文件为 Claude Code (claude.ai/code) 在此仓库中工作时提供指导。

## 项目概述

AutoTranslator —— 一个 macOS 划词翻译工具，鼠标松开时自动检测选中文本并弹出悬浮翻译窗口。支持谷歌翻译和基于大模型的翻译（DeepSeek，通过阿里百炼 DashScope 的 OpenAI 兼容接口）。仅限 macOS（需要辅助功能权限和 Quartz Event Taps）。

**技术栈**: Swift 5.9+ / AppKit / Swift Package Manager

## 常用命令

```bash
# 构建
swift build

# 构建并运行（裸可执行，无 .app bundle —— 系统通知不可用）
swift build && .build/debug/AutoTranslator

# 以 Release 模式构建
swift build -c release

# 运行 Release 版本
.build/release/AutoTranslator

# 打包为 .app bundle（让通知 / 菜单栏 / LSUIElement 正常工作）
make app          # Debug 版 → .build/debug/AutoTranslator.app
make app-release  # Release 版 → .build/release/AutoTranslator.app
make run-app      # 打包并以 .app 形式启动
```

没有配置代码检查工具或测试框架。依赖均为系统框架（AppKit、CoreGraphics、ApplicationServices），无需外部 Swift 包。

## 架构

```
Package.swift                 # Swift Package Manager 项目清单
Sources/AutoTranslator/
  main.swift                  # 入口：配置加载、权限检查、NSApplication 启动
  AppController.swift         # 主控制器：鼠标事件、翻译流程、前端与翻译器之间的胶水层
  MouseMonitor.swift          # CGEventTap 封装：监听鼠标按下/拖拽/松开
  TextSelector.swift          # 文本选择器：Accessibility API + 剪贴板回退
  Translators/
    TranslatorProtocol.swift  # 翻译器协议：translate / translateStream
    GoogleTranslator.swift    # Google 翻译（translate.googleapis.com）
    LLMTranslator.swift       # 大模型翻译（OpenAI 兼容接口，阿里百炼 DashScope）
  UI/
    DesignSystem.swift        # 布局常量、颜色调色板、视图样式辅助函数
    FloatingWindow.swift      # macOS 悬浮 NSPanel 窗口，包含原文/译文卡片、工具栏、语言选择器
```

**翻译流程**：`AppController` 持有 `MouseMonitor`、`TextSelector`、`FloatingWindow` 和当前 `TranslatorProtocol` 实例。`MouseMonitor` 通过 Quartz `CGEventTap` 全局监听鼠标左键松开事件。鼠标松开后，通过 macOS 辅助功能 API 读取选中文本（回退方案：模拟 Cmd+C 后读取剪贴板）。文本在后台 Task 中发送给翻译器，结果通过 `MainActor.run` 在 `FloatingWindow` 中展示。

**翻译器接口**：两种后端都遵循 `TranslatorProtocol`，提供 `translate(_:) async throws -> String` 和 `translateStream(_:) -> AsyncThrowingStream` 方法。`LLMTranslator` 使用 `URLSession` 直接调用阿里百炼 DashScope API，支持流式响应。

**FloatingWindow**：无边框 `NSPanel`（`BorderlessWindow`），层级为 `NSFloatingWindowLevel`。全部使用代码构建 UI（无 nib/xib）。自定义渐变背景（`PanelBackgroundView`），带有柔和光晕效果。窗口拖动后自动固定（`autoPin`），并保存/恢复位置。

## 环境变量

| 变量 | 用途 |
|---|---|
| `TRANSLATOR_BACKEND` | `google`（默认）或 `llm` |
| `DEEPSEEK_API_KEY` / `LLM_API_KEY` | 大模型翻译的 API Key（使用 `llm` 后端时必填） |

配置文件：`~/Library/Application Support/AutoTranslator/config.json`，可设置上述环境变量。

## 关键约束

- **仅限 macOS** —— 重度依赖 Quartz Event Taps、辅助功能 API 和 AppKit。
- 应用必须授予**辅助功能权限**（系统设置 → 隐私与安全性 → 辅助功能），否则会报错退出。
- 大模型后端使用阿里百炼 DashScope（`dashscope.aliyuncs.com`）作为 base_url，而非默认的 DeepSeek 或 OpenAI 端点。模型为 `deepseek-v3.2`，`enable_thinking: false`。
- 当源语言为 `auto`（自动检测）时，语言互换功能禁用，因为自动检测没有固定的源语言可以互换。
- 项目使用 Swift 5.9 特性（`AsyncThrowingStream`、`@MainActor`），最低支持 macOS 13 Ventura。