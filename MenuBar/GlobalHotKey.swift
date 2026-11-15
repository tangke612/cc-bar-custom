import AppKit
import Carbon.HIToolbox

/// 系统级全局快捷键（Carbon `RegisterEventHotKey`，无需辅助功能授权）。
@MainActor
final class GlobalHotKey {
    nonisolated private static let signature = OSType(0x4343_4B42)
    private static var nextID: UInt32 = 1

    nonisolated let id: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let action: @MainActor () -> Void

    /// - Parameters:
    ///   - keyCode: Carbon 虚拟键码（如 `kVK_ANSI_K`）。
    ///   - modifiers: Carbon 修饰键掩码（如 `controlKey | optionKey`）。
    init(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        self.id = Self.nextID
        Self.nextID &+= 1
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        self.action = action
    }

    var isRegistered: Bool { hotKeyRef != nil }

    func register() {
        guard hotKeyRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var eventHotKeyID = EventHotKeyID()
                let paramStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &eventHotKeyID
                )
                guard paramStatus == noErr else { return OSStatus(eventNotHandledErr) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                guard eventHotKeyID.signature == GlobalHotKey.signature,
                      eventHotKeyID.id == hotKey.id else {
                    return OSStatus(eventNotHandledErr)
                }
                MainActor.assumeIsolated {
                    hotKey.action()
                }
                return noErr
            },
            1,
            &spec,
            userData,
            &handlerRef
        )
        guard status == noErr else { return }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let regStatus = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if regStatus != noErr {
            hotKeyRef = nil
            if let handlerRef {
                RemoveEventHandler(handlerRef)
                self.handlerRef = nil
            }
            AppLog.error(.app, "[hotkey] register id=\(id) failed: \(regStatus)")
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}
