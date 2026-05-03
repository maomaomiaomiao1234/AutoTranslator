import Cocoa

// MARK: - Config Loader

func loadRuntimeConfig() -> [String: String] {
    let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AutoTranslator")
    let configPath = configDir.appendingPathComponent("config.json")

    guard let data = try? Data(contentsOf: configPath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
        return [:]
    }
    var result: [String: String] = [:]
    for key in ["TRANSLATOR_BACKEND", "DEEPSEEK_API_KEY", "LLM_API_KEY"] {
        if let value = json[key], !value.trimmingCharacters(in: .whitespaces).isEmpty {
            result[key] = value.trimmingCharacters(in: .whitespaces)
        }
    }
    return result
}

func applyRuntimeConfig() {
    let config = loadRuntimeConfig()
    for (key, value) in config {
        if ProcessInfo.processInfo.environment[key] == nil {
            setenv(key, value, 0)
        }
    }
}

func ensureAccessibilityPermission() -> Bool {
    if AXIsProcessTrusted() { return true }

    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if AXIsProcessTrustedWithOptions(options) { return true }

    fputs("[AutoTranslator] 需要辅助功能权限，请在 系统设置 > 隐私与安全性 > 辅助功能 中允许 AutoTranslator。\n", stderr)
    return false
}

// MARK: - Entry Point

func main() {
    applyRuntimeConfig()

    let appSupportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AutoTranslator")
    try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)

    guard ensureAccessibilityPermission() else {
        exit(1)
    }

    let backend = ProcessInfo.processInfo.environment["TRANSLATOR_BACKEND"] ?? "llm"
    if backend == "llm" {
        let apiKey = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
            ?? ProcessInfo.processInfo.environment["LLM_API_KEY"]
        if apiKey == nil || apiKey!.isEmpty {
            fputs("[AutoTranslator] 未设置 API Key，回退到谷歌翻译。请在 ~/Library/Application Support/AutoTranslator/config.json 中配置。\n", stderr)
            setenv("TRANSLATOR_BACKEND", "google", 1)
        }
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    signal(SIGINT, SIG_DFL)

    let controller = AppController()
    controller.start()

    let backendName = ProcessInfo.processInfo.environment["TRANSLATOR_BACKEND"] == "google" ? "谷歌翻译" : "大模型"
    fputs("[AutoTranslator] 翻译器已启动（\(backendName)），支持语言切换\n", stderr)

    app.run()
}

main()
