import AppKit

/// 应用主题外观偏好。
enum Theme: String, CaseIterable {
    case system
    case light
    case dark

    /// 菜单/偏好设置中显示的中文名。
    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    /// 对应的 NSAppearance；`.system` 返回 nil 表示跟随系统。
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }

    /// 把当前主题应用到整个 NSApplication。所有窗口（含 FloatingWindow）
    /// 都会通过 `viewDidChangeEffectiveAppearance` 自动刷新。
    func apply() {
        NSApp.appearance = nsAppearance
    }

    static let `default`: Theme = .system

    static func from(rawValue raw: String?) -> Theme {
        guard let raw, let value = Theme(rawValue: raw) else { return .default }
        return value
    }
}
