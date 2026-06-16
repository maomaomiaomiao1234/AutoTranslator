import Carbon
import Foundation

final class GlobalHotKeyManager {
    enum Command: UInt32 {
        case toggleMonitoring = 1
    }

    static let monitoringShortcutLabel = "⌥E"

    var onToggleMonitoring: (() -> Void)?

    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private let signature = GlobalHotKeyManager.fourCharCode("ATKH")

    deinit {
        stop()
    }

    func start() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyEventHandler,
            1,
            &eventType,
            userData,
            &eventHandler
        )

        guard installStatus == noErr else {
            AppLog.error("注册全局快捷键处理器失败: \(installStatus)")
            eventHandler = nil
            return
        }

        register(
            command: .toggleMonitoring,
            keyCode: UInt32(kVK_ANSI_E),
            shortcutLabel: Self.monitoringShortcutLabel
        )
    }

    func stop() {
        for hotKey in hotKeys {
            UnregisterEventHotKey(hotKey)
        }
        hotKeys.removeAll()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func register(command: Command, keyCode: UInt32, shortcutLabel: String) {
        let hotKeyID = EventHotKeyID(signature: signature, id: command.rawValue)
        var hotKeyRef: EventHotKeyRef?
        let modifiers = UInt32(optionKey)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let hotKeyRef else {
            AppLog.error("注册全局快捷键 \(shortcutLabel) 失败: \(status)")
            return
        }

        hotKeys.append(hotKeyRef)
    }

    private func handle(commandID: UInt32) {
        guard let command = Command(rawValue: commandID) else { return }
        switch command {
        case .toggleMonitoring:
            onToggleMonitoring?()
        }
    }

    private static let hotKeyEventHandler: EventHandlerUPP = { _, eventRef, userData in
        guard let eventRef, let userData else { return noErr }

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else { return status }

        let manager = Unmanaged<GlobalHotKeyManager>
            .fromOpaque(userData)
            .takeUnretainedValue()
        manager.handle(commandID: hotKeyID.id)
        return noErr
    }

    private static func fourCharCode(_ string: String) -> OSType {
        string.utf8.reduce(0) { result, character in
            (result << 8) + OSType(character)
        }
    }
}
