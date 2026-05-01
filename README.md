# AutoTranslator
划词翻译：光标**选中后自动翻译**，无需按键操作

### 弹出翻译窗口
<img src="/test.png" alt="image-show" style="zoom:25%;" />

### 运行方式
uv sync
python backend/app/main.py

### 构建 macOS App
项目已经补好了 `py2app` 打包入口，可直接构建 `.app`：

```bash
uv run --with py2app python setup.py py2app
```

调试时也可以先构建 alias 版本：

```bash
uv run --with py2app python setup.py py2app -A
```

构建完成后，应用产物位于：

```bash
dist/AutoTranslator.app
```

说明：

- `py2app -A` 是开发版 alias 包，适合本机调试。
- 完整 standalone 包依赖可重打包的 Framework Python。
- 如果你当前使用的是 `uv` 自带 Python，完整构建可能会被 `py2app` 限制；这时请安装 python.org 的 Python 3.12 后再执行正式构建。

### 首次启动权限
首次启动 App 时，系统会要求授予“辅助功能”权限，否则无法监听选中文本。

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
codesign --deep --force --verify --verbose --options runtime --sign "Developer ID Application: YOUR NAME" dist/AutoTranslator.app
xcrun notarytool submit dist/AutoTranslator.app --keychain-profile YOUR_PROFILE --wait
xcrun stapler staple dist/AutoTranslator.app
```
