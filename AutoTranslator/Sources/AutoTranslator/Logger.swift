import Foundation

enum AppLog {
    static let isDebugEnabled: Bool = {
#if DEBUG_LOG
        return true
#else
        let environment = ProcessInfo.processInfo.environment
        return isEnabled(environment["DEBUG_LOG"])
            || isEnabled(environment["AUTOTRANSLATOR_DEBUG_LOG"])
            || isEnabled(environment["AUTO_TRANSLATOR_DEBUG_LOG"])
#endif
    }()

    static func debug(_ message: @autoclosure () -> String) {
        guard isDebugEnabled else { return }
        write(message())
    }

    static func error(_ message: @autoclosure () -> String) {
        write(message())
    }

    private static func write(_ message: String) {
        fputs("[AutoTranslator] \(message)\n", stderr)
    }

    private static func isEnabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }
}
