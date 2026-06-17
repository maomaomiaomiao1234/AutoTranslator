import Foundation

enum FloatingWindowMode: String, CaseIterable, Identifiable {
    case standard
    case minimal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard:
            return "完整"
        case .minimal:
            return "极简"
        }
    }

    static func from(rawValue: String?) -> FloatingWindowMode {
        guard let rawValue,
              let mode = FloatingWindowMode(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .standard
        }
        return mode
    }
}
