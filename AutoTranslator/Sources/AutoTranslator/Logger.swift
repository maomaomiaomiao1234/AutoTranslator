import Foundation

enum AppLog {
    nonisolated static let isDebugEnabled: Bool = {
#if DEBUG_LOG
        return true
#else
        let environment = ProcessInfo.processInfo.environment
        return isEnabled(environment["DEBUG_LOG"])
#endif
    }()

    nonisolated static func debug(_ message: @autoclosure () -> String) {
        guard isDebugEnabled else { return }
        write(message())
    }

    nonisolated static func error(_ message: @autoclosure () -> String) {
        write(message())
    }

    nonisolated private static func write(_ message: String) {
        fputs("[AutoTranslator] \(message)\n", stderr)
    }

    nonisolated private static func isEnabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }
}
