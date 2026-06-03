# AutoTranslator

划词翻译：光标**选中后自动翻译**，无需按键操作

### 弹出翻译窗口

### 运行方式（Swift 原生）

```bash
# 构建
swift build

# 运行（裸可执行，无 .app bundle）
swift build && .build/debug/AutoTranslator

# Release 模式
swift build -c release && .build/release/AutoTranslator
```

### 打包为 .app

```bash
# Debug 版
make app

# Release 版
make app-release

# 打包并以 .app 形式启动
make run-app
```

### 首次启动权限

首次启动 App 时，系统会要求授予"辅助功能"权限，否则无法监听选中文本。

路径：

```text
系统设置 > 隐私与安全性 > 辅助功能
```

### Finder 启动时的配置文件

Finder 双击启动 `.app` 时不会继承终端环境变量。若要在桌面版中使用大模型翻译，请创建：

```text
~/Library/Application Support/AutoTranslator/config.json
```

示例：

```json
{
  "TRANSLATOR_BACKEND": "llm",
  "DEEPSEEK_API_KEY": "sk-xxxxxx"
}
```

未配置 API Key 时，应用会自动回退到 Google 翻译。

### 签名与公证

本仓库当前已经具备生成 `.app` 的基础结构；如果要发给其他 Mac 用户，还需要你自己的 Apple Developer 证书继续做：

```bash
codesign --deep --force --verify --verbose --options runtime --sign "Developer ID Application: YOUR NAME" .build/release/AutoTranslator.app
xcrun notarytool submit .build/release/AutoTranslator.app --keychain-profile YOUR_PROFILE --wait
xcrun stapler staple .build/release/AutoTranslator.app
```
